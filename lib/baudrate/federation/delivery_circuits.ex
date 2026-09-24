defmodule Baudrate.Federation.DeliveryCircuits do
  @moduledoc """
  Per-domain circuit breaker for outbound delivery.

  Without it, a remote server that is down took worker slots one job at a time:
  every job for it waited out its own connection or request timeout, while
  deliveries to healthy servers queued behind them. With it, once a domain has
  failed `delivery_circuit_threshold` times in a row (default 5), its jobs are
  held back together until `open_until`, and then one job is sent as a probe.
  A probe that fails opens the circuit again for the next step of
  `delivery_circuit_schedule` (default 5 min, 30 min, 2 h, 6 h, 12 h, then
  24 h); any response that shows the server is reachable closes it.

  Held-back jobs do not use up their own attempts, so a job whose domain stays
  unreachable is abandoned by age instead (`Delivery.expire_held_jobs/0`).

  ## What counts

    * **Unreachable:** connection and TLS errors, timeouts, DNS failures, HTTP
      5xx and 429.
    * **Reachable:** success, and every other HTTP response (a 401, 404 or 410
      is about the job, not the server), including an oversized response.
    * **Neither:** failures on our side — no signing key, a URL our SSRF guard
      refuses, a blocked domain. They leave the circuit as it is.

  State is a table (`DeliveryCircuit`), not ETS, so a restart does not send a
  burst of jobs to every server that was down, and the detailed health view
  (Phase 2D) can read it.
  """

  require Logger

  import Ecto.Query

  alias Baudrate.Federation.DeliveryCircuit
  alias Baudrate.Repo

  @default_threshold 5
  @default_schedule [300, 1800, 7200, 21_600, 43_200, 86_400]

  @type outcome :: :reachable | :unreachable | :neutral

  @doc """
  Classifies the result of an HTTP delivery for the breaker.
  """
  @spec outcome({:ok, term()} | {:error, term()}) :: outcome()
  def outcome({:ok, _response}), do: :reachable
  def outcome({:error, {:http_error, status, _body}}) when status == 429, do: :unreachable
  def outcome({:error, {:http_error, status, _body}}) when status >= 500, do: :unreachable
  def outcome({:error, {:http_error, _status, _body}}), do: :reachable
  def outcome({:error, :response_too_large}), do: :reachable
  def outcome({:error, {:request_failed, _reason}}), do: :unreachable
  def outcome({:error, :dns_resolution_failed}), do: :unreachable
  def outcome({:error, :timeout}), do: :unreachable
  def outcome(_other), do: :neutral

  @doc """
  Records a delivery outcome for `domain`.

  Returns `:closed` when a reachable result closed a circuit that had opened,
  `:opened` when a failure opened (or reopened) it, and `:ok` otherwise.
  """
  @spec record(String.t() | nil, outcome(), term()) :: :ok | :opened | :closed
  def record(domain, outcome, error \\ nil)

  def record(nil, _outcome, _error), do: :ok
  def record(_domain, :neutral, _error), do: :ok

  def record(domain, :reachable, _error) do
    case Repo.delete_all(from(c in DeliveryCircuit, where: c.domain == ^domain, select: c.trips)) do
      {1, [trips]} when trips > 0 ->
        Logger.info("federation.delivery_circuit_closed: domain=#{domain}")
        :closed

      _ ->
        :ok
    end
  end

  def record(domain, :unreachable, error) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      DeliveryCircuit,
      [%{domain: domain, failures: 0, trips: 0, inserted_at: now, updated_at: now}],
      on_conflict: :nothing,
      conflict_target: :domain
    )

    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.one(from(c in DeliveryCircuit, where: c.domain == ^domain, lock: "FOR UPDATE")) do
          # A success on another job closed the circuit in between; it wins.
          nil -> :ok
          circuit -> apply_failure(circuit, now, error)
        end
      end)

    result
  end

  defp apply_failure(circuit, now, error) do
    failures = circuit.failures + 1

    {changes, result} =
      cond do
        # Already open: this job started before the circuit opened.
        circuit.trips > 0 and DateTime.compare(circuit.open_until, now) == :gt ->
          {%{}, :ok}

        # Open and past `open_until`: this was a probe, and it failed.
        circuit.trips > 0 ->
          trips = circuit.trips + 1
          {%{trips: trips, open_until: reopen_at(now, trips)}, :opened}

        failures >= threshold() ->
          {%{trips: 1, open_until: reopen_at(now, 1)}, :opened}

        true ->
          {%{}, :ok}
      end

    circuit
    |> Ecto.Changeset.change(
      Map.merge(changes, %{
        failures: failures,
        last_error: error |> inspect() |> String.slice(0, 1000),
        updated_at: now
      })
    )
    |> Repo.update!()
    |> log_opened(result)

    result
  end

  defp log_opened(circuit, :opened) do
    Logger.warning(
      "federation.delivery_circuit_open: domain=#{circuit.domain} failures=#{circuit.failures} trips=#{circuit.trips} until=#{DateTime.to_iso8601(circuit.open_until)}"
    )
  end

  defp log_opened(_circuit, _result), do: :ok

  defp reopen_at(now, trips) do
    schedule = config(:delivery_circuit_schedule, @default_schedule)
    seconds = Enum.at(schedule, min(trips, length(schedule)) - 1)
    DateTime.add(now, seconds, :second)
  end

  @doc """
  A query for domains whose circuit has opened, whether or not it may be probed
  yet. Their jobs are only ever sent as probes.
  """
  @spec tripped_query() :: Ecto.Query.t()
  def tripped_query do
    from(c in DeliveryCircuit, where: c.trips > 0)
  end

  @doc """
  Returns the circuits that are open or waiting for a probe, most recently
  opened first.
  """
  @spec list_tripped() :: [DeliveryCircuit.t()]
  def list_tripped do
    tripped_query()
    |> order_by([c], desc: c.updated_at, asc: c.domain)
    |> Repo.all()
  end

  @doc """
  Closes `domain`'s circuit by hand (Phase 7E): the admin fixed a problem on
  our side, or knows the server is back, and does not want its jobs held
  until the next probe. Deleting the row is what "healthy" already means, so
  the held jobs are sent on the worker's next pass; if the server is in fact
  still down, five more failures open the circuit again.

  Returns `{:ok, circuit}` with the row as it was, or `{:error, :not_found}`
  when the domain has no open circuit.
  """
  @spec close(String.t()) :: {:ok, DeliveryCircuit.t()} | {:error, :not_found}
  def close(domain) when is_binary(domain) do
    from(c in DeliveryCircuit, where: c.domain == ^domain and c.trips > 0, select: c)
    |> Repo.delete_all()
    |> case do
      {1, [circuit]} ->
        Logger.info("federation.circuit_closed_by_admin: domain=#{domain}")
        {:ok, circuit}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes rows not updated for 30 days: failures that never reached the
  threshold, for domains that were not contacted again. Returns the count.
  """
  @spec purge_idle() :: non_neg_integer()
  def purge_idle do
    cutoff = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.truncate(:second)
    {count, _} = Repo.delete_all(from(c in DeliveryCircuit, where: c.updated_at < ^cutoff))
    count
  end

  @doc "The number of consecutive failures that opens a circuit."
  @spec threshold() :: pos_integer()
  def threshold, do: config(:delivery_circuit_threshold, @default_threshold)

  defp config(key, default) do
    Application.get_env(:baudrate, Baudrate.Federation, []) |> Keyword.get(key) || default
  end
end
