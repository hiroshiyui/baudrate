defmodule Baudrate.Federation.Inbound do
  @moduledoc """
  The inbound queue: an activity is checked and stored while the remote server
  waits, and processed afterwards by `Federation.InboundWorker` (Phase 2C,
  ADR 0034).

  ## In the request

  After the plugs have verified the HTTP signature, rate-limited the domain
  and capped the body at 256 KB, `accept/4` runs the admission checks
  (`InboxHandler.admit/2`: well-formed, allowed domain, actor not suspended,
  not claiming a local actor, signed by its own actor — the order they always
  ran in), stores the activity and answers. A redelivery of an activity already
  stored from the same actor is answered the same way and not stored again.

  ## Outside the request

  `process/1` claims the row (counting the attempt first, so an activity that
  crashes the processor cannot be retried forever), runs
  `InboxHandler.handle/3` — which repeats the admission checks, since a domain
  may have been blocked in the meantime — and records the outcome. A handler
  that refuses an activity (`{:error, reason}`) marks it rejected, as the 422
  response used to: senders do not retry those. A crash or timeout is retried
  after a backoff, up to `inbound_max_attempts` (default 3).

  Processing is at-least-once: a restart during processing runs the activity
  again, and the handlers are idempotent (unique `ap_id`s, follower rows).
  """

  require Logger

  import Ecto.Query

  alias Baudrate.Federation.{InboundActivity, InboundWorker, InboxHandler, RemoteActor}
  alias Baudrate.Repo

  @default_max_attempts 3
  @retry_backoff [30, 300]
  @retention_days 7

  @type target :: :shared | {:user, struct()} | {:board, struct()}

  @doc """
  Admits and stores an activity received at `target`'s inbox.

  Returns `:ok` when the activity was stored or had already been stored, and
  `{:error, reason}` when it fails admission. With `federation_async: false`
  (tests) the activity is also processed before this returns.
  """
  @spec accept(term(), String.t(), RemoteActor.t(), target()) :: :ok | {:error, term()}
  def accept(activity, raw_body, %RemoteActor{} = remote_actor, target) do
    with {:ok, activity} <- InboxHandler.admit(activity, remote_actor) do
      case store(activity, raw_body, remote_actor, target) do
        {:ok, %InboundActivity{id: id}} ->
          after_store(id)
          :ok

        :duplicate ->
          Logger.info(
            "federation.inbound_duplicate: actor=#{remote_actor.ap_id} id=#{activity["id"]}"
          )

          :ok
      end
    end
  end

  defp after_store(id) do
    case Application.get_env(:baudrate, :federation_async, true) do
      false -> process(id)
      :discard -> :ok
      _ -> InboundWorker.wake()
    end
  end

  @doc """
  Stores an admitted activity. Returns `{:ok, row}`, or `:duplicate` when the
  same actor's activity with the same id is already stored.
  """
  @spec store(map(), String.t(), RemoteActor.t(), target()) ::
          {:ok, InboundActivity.t()} | :duplicate
  def store(%{"id" => activity_id, "type" => type}, raw_body, remote_actor, target) do
    {target_type, target_id} = encode_target(target)

    row = %InboundActivity{
      activity_id: activity_id,
      activity_type: String.slice(type, 0, 64),
      activity_json: raw_body,
      remote_actor_id: remote_actor.id,
      target_type: target_type,
      target_id: target_id
    }

    case Repo.insert(row,
           on_conflict: :nothing,
           conflict_target: [:remote_actor_id, :activity_id]
         ) do
      {:ok, %InboundActivity{id: nil}} -> :duplicate
      {:ok, stored} -> {:ok, stored}
    end
  end

  defp encode_target(:shared), do: {"shared", nil}
  defp encode_target({:user, %{id: id}}), do: {"user", id}
  defp encode_target({:board, %{id: id}}), do: {"board", id}

  @doc """
  Processes one stored activity. Returns the outcome: `:processed`,
  `:rejected`, `:failed` (out of attempts) or `:skipped` (no longer pending).
  Raises if the handler raises; `InboundWorker` records that through
  `record_interrupted/2`.
  """
  @spec process(integer()) :: :processed | :rejected | :failed | :skipped
  def process(id) do
    max = max_attempts()

    case claim(id) do
      nil ->
        :skipped

      # Attempts are counted before the work, so a row still pending past the
      # limit is one whose processing kept taking the node down with it.
      %InboundActivity{attempts: attempts} = row when attempts > max ->
        finish(row, :failed, "gave up after #{max} attempts")

      row ->
        case run(row) do
          :ok ->
            finish(row, :processed, nil)

          {:error, reason} ->
            Logger.info(
              "federation.inbound_rejected: id=#{row.id} type=#{row.activity_type} reason=#{inspect(reason)}"
            )

            finish(row, :rejected, inspect(reason))
        end
    end
  end

  # Counts the attempt before any work, in the same statement that checks the
  # row is still pending.
  defp claim(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.update_all(
           from(a in InboundActivity, where: a.id == ^id and a.status == "pending", select: a),
           inc: [attempts: 1],
           set: [updated_at: now]
         ) do
      {1, [row]} -> row
      {0, _} -> nil
    end
  end

  defp run(row) do
    with {:ok, activity} <- Jason.decode(row.activity_json || ""),
         %RemoteActor{} = actor <- Repo.get(RemoteActor, row.remote_actor_id),
         {:ok, target} <- load_target(row) do
      InboxHandler.handle(activity, actor, target)
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      nil -> {:error, :actor_gone}
      {:error, _} = error -> error
    end
  end

  defp load_target(%{target_type: "shared"}), do: {:ok, :shared}

  defp load_target(%{target_type: "user", target_id: id}) do
    case Repo.get(Baudrate.Setup.User, id) do
      nil -> {:error, :target_gone}
      user -> {:ok, {:user, user}}
    end
  end

  # A board that stopped federating after the activity arrived no longer has an
  # inbox, so the activity is refused as the request would be now.
  defp load_target(%{target_type: "board", target_id: id}) do
    case Repo.get(Baudrate.Content.Board, id) do
      nil ->
        {:error, :target_gone}

      board ->
        if Baudrate.Content.Board.federated?(board),
          do: {:ok, {:board, board}},
          else: {:error, :target_gone}
    end
  end

  defp finish(row, status, error) when status in [:processed, :rejected, :failed] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(a in InboundActivity, where: a.id == ^row.id),
      set: [
        status: Atom.to_string(status),
        last_error: error && String.slice(error, 0, 1000),
        activity_json: nil,
        processed_at: now,
        updated_at: now
      ]
    )

    status
  end

  @doc """
  Records a processing attempt that crashed or ran past its deadline: retried
  after a backoff, or marked failed once out of attempts.
  """
  @spec record_interrupted(integer(), term()) :: :ok
  def record_interrupted(id, reason) do
    case Repo.get(InboundActivity, id) do
      %InboundActivity{status: "pending"} = row ->
        error = inspect(reason) |> String.slice(0, 1000)

        if row.attempts >= max_attempts() do
          Logger.error("federation.inbound_failed: id=#{row.id} type=#{row.activity_type}")
          finish(row, :failed, error)
        else
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          delay = Enum.at(@retry_backoff, min(row.attempts, length(@retry_backoff)) - 1)

          Repo.update_all(from(a in InboundActivity, where: a.id == ^row.id),
            set: [
              last_error: error,
              next_attempt_at: DateTime.add(now, delay, :second),
              updated_at: now
            ]
          )
        end

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Deletes finished rows older than seven days, the window in which a
  redelivered activity is still recognised. Returns the count.
  """
  @spec purge_finished() :: non_neg_integer()
  def purge_finished do
    cutoff =
      DateTime.utc_now() |> DateTime.add(-@retention_days, :day) |> DateTime.truncate(:second)

    {count, _} =
      Repo.delete_all(
        from(a in InboundActivity, where: a.status != "pending" and a.processed_at < ^cutoff)
      )

    count
  end

  @doc "Counts pending activities; the inbound backlog."
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    Repo.aggregate(from(a in InboundActivity, where: a.status == "pending"), :count)
  end

  defp max_attempts do
    Application.get_env(:baudrate, Baudrate.Federation, [])
    |> Keyword.get(:inbound_max_attempts, @default_max_attempts)
  end
end
