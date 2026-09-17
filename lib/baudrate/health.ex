defmodule Baudrate.Health do
  @moduledoc """
  The detailed health report (Phase 2D): the checks an operator polls to hear
  about a problem before members do.

  The public `/health` only answers whether the application can reach its
  database. This report goes further, and is served only on a loopback
  listener (`BaudrateWeb.HealthDetail`), never through nginx. Decision P2-D1
  made it the one place an operator polls, instead of a metrics endpoint.

  ## Checks

  | Check | Fails when |
  |-------|------------|
  | `database` | `SELECT 1` does not answer |
  | `delivery_queue` | a delivery has been due for more than 15 minutes. Jobs held back by an open circuit are not counted: they are waiting on purpose |
  | `inbound_queue` | an inbox activity has been waiting for more than 10 minutes |
  | `workers` | `DeliveryWorker`, `InboundWorker`, `FeedWorker` or `SessionCleaner` has not completed a run for three of its intervals (at least 5 minutes), counting from boot for a worker that has not run yet |
  | `disk` | free space under the uploads directory is below 1 GiB or 10% of the filesystem, the floor backups also keep |
  | `backup` | the newest complete backup in `BAUDRATE_BACKUP_DIR` is more than 26 hours old, or there is none. Skipped when no backup directory is configured |

  The queue checks are skipped while federation is switched off. Each check
  runs with a 5-second limit; one that runs out fails, so a hung database or
  filesystem shows up rather than hanging the report.

  The report holds counts, ages and statuses only: no content, account names
  or remote domains, since anyone with a shell on the host can read it.
  """

  import Ecto.Query

  alias Baudrate.Backup
  alias Baudrate.Backup.Snapshots
  alias Baudrate.Federation.{DeliveryCircuit, DeliveryJob, InboundActivity}
  alias Baudrate.Health.Heartbeat
  alias Baudrate.Repo

  @gib 1024 * 1024 * 1024
  @check_timeout_ms 5_000
  @delivery_max_due_seconds 15 * 60
  @inbound_max_wait_seconds 10 * 60
  @backup_max_age_seconds 26 * 3600
  @min_stale_ms 5 * 60_000

  @checks [:database, :delivery_queue, :inbound_queue, :workers, :disk, :backup]

  @type status :: :ok | :fail | :skipped
  @type report :: %{status: :ok | :fail, checks: %{atom() => map()}}

  @doc """
  Runs every check and returns `%{status: :ok | :fail, checks: %{name => result}}`.
  Each result has a `:status` of `:ok`, `:fail` or `:skipped`, and a `:reason`
  unless it is `:ok`.

  Options, for tests: `:now` (`DateTime`), `:backup_dir`, `:free_space`
  (a function like `Backup.free_space/1`), `:database` (a zero-arity function
  returning `:ok` or `{:error, reason}`), `:last_beat` (a function from worker
  name to monotonic milliseconds or `nil`), `:monotonic_now_ms`, `:uptime_ms`,
  `:federation_enabled?`, `:timeout_ms` and `:only` (a list of check names).
  """
  @spec report(keyword()) :: report()
  def report(opts \\ []) do
    names = Keyword.get(opts, :only, @checks)
    timeout = Keyword.get(opts, :timeout_ms, @check_timeout_ms)

    checks =
      names
      |> Task.async_stream(&{&1, run_check(&1, opts)},
        timeout: timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true,
        ordered: true
      )
      |> Map.new(fn
        {:ok, {name, result}} -> {name, result}
        {:exit, {name, :timeout}} -> {name, fail("did not finish within #{timeout} ms")}
        {:exit, {name, _reason}} -> {name, fail("raised an error")}
      end)

    status = if Enum.any?(checks, fn {_, c} -> c.status == :fail end), do: :fail, else: :ok
    %{status: status, checks: checks}
  end

  # Any exception becomes a failed check with a fixed reason: an error message
  # could carry query text or a path, and the report stays free of both.
  defp run_check(name, opts) do
    check(name, opts)
  rescue
    _ -> fail("raised an error")
  end

  # --- database ---

  defp check(:database, opts) do
    probe = Keyword.get(opts, :database, &select_one/0)

    case probe.() do
      :ok -> ok(%{})
      {:error, _} -> fail("the database did not answer")
    end
  end

  # --- delivery queue ---

  defp check(:delivery_queue, opts) do
    if federation_enabled?(opts) do
      now = now(opts)

      due =
        from(j in DeliveryJob,
          as: :job,
          where: j.status in ["pending", "failed"],
          where: is_nil(j.next_retry_at) or j.next_retry_at <= ^now,
          where:
            not exists(
              from(c in DeliveryCircuit,
                where: c.domain == parent_as(:job).domain and c.trips > 0,
                select: 1
              )
            )
        )

      waiting =
        Repo.aggregate(from(j in DeliveryJob, where: j.status in ["pending", "failed"]), :count)

      oldest_due =
        Repo.one(from(j in due, select: min(coalesce(j.next_retry_at, j.inserted_at))))

      open_circuits = Repo.aggregate(from(c in DeliveryCircuit, where: c.trips > 0), :count)
      due_seconds = seconds_since(oldest_due, now)

      details = %{waiting: waiting, oldest_due_seconds: due_seconds, open_circuits: open_circuits}

      if due_seconds > @delivery_max_due_seconds,
        do: fail("a delivery has been due for more than 15 minutes", details),
        else: ok(details)
    else
      skipped("federation is switched off")
    end
  end

  # --- inbound queue ---

  defp check(:inbound_queue, opts) do
    if federation_enabled?(opts) do
      now = now(opts)
      day_ago = DateTime.add(now, -86_400, :second)

      pending = from(a in InboundActivity, where: a.status == "pending")

      oldest =
        Repo.one(
          from(a in pending,
            where: is_nil(a.next_attempt_at) or a.next_attempt_at <= ^now,
            select: min(coalesce(a.next_attempt_at, a.inserted_at))
          )
        )

      failed_last_day =
        Repo.aggregate(
          from(a in InboundActivity, where: a.status == "failed" and a.processed_at > ^day_ago),
          :count
        )

      wait_seconds = seconds_since(oldest, now)

      details = %{
        pending: Repo.aggregate(pending, :count),
        oldest_waiting_seconds: wait_seconds,
        failed_last_24h: failed_last_day
      }

      if wait_seconds > @inbound_max_wait_seconds,
        do: fail("an inbox activity has waited for more than 10 minutes", details),
        else: ok(details)
    else
      skipped("federation is switched off")
    end
  end

  # --- workers ---

  defp check(:workers, opts) do
    last_beat = Keyword.get(opts, :last_beat, &Heartbeat.last/1)

    now_ms =
      Keyword.get_lazy(opts, :monotonic_now_ms, fn -> System.monotonic_time(:millisecond) end)

    uptime_ms = Keyword.get_lazy(opts, :uptime_ms, &Heartbeat.uptime_ms/0)

    workers =
      Map.new(worker_intervals(), fn {name, interval_ms} ->
        stale_ms = max(3 * interval_ms, @min_stale_ms)

        result =
          case last_beat.(name) do
            nil when uptime_ms < stale_ms ->
              %{status: :ok, last_run_seconds: nil}

            nil ->
              %{status: :fail, last_run_seconds: nil}

            at ->
              age_ms = now_ms - at
              status = if age_ms > stale_ms, do: :fail, else: :ok
              %{status: status, last_run_seconds: div(max(age_ms, 0), 1000)}
          end

        {name, result}
      end)

    stale = for {name, %{status: :fail}} <- workers, do: name

    if stale == [],
      do: ok(%{workers: workers}),
      else: fail("a worker has stopped completing runs", %{workers: workers, stale: stale})
  end

  # --- disk ---

  defp check(:disk, opts) do
    free_space = Keyword.get(opts, :free_space, &Backup.free_space/1)

    with {:ok, uploads} <- Backup.uploads_dir(),
         {:ok, %{free: free, total: total}} <- free_space.(uploads) do
      floor = max(@gib, div(total, 10))
      details = %{free_bytes: free, total_bytes: total, floor_bytes: floor}

      if free < floor,
        do: fail("free space under the uploads directory is below the floor", details),
        else: ok(details)
    else
      {:error, _} -> fail("could not read free space under the uploads directory")
    end
  end

  # --- backup ---

  defp check(:backup, opts) do
    case Keyword.get_lazy(opts, :backup_dir, &configured_backup_dir/0) do
      dir when dir in [nil, ""] ->
        skipped("no backup directory is configured")

      dir ->
        now = now(opts)

        case Snapshots.list(dir) do
          [] ->
            fail("no complete backup found")

          [newest | _] = backups ->
            age = seconds_since(backup_time(newest), now)
            details = %{newest_age_seconds: age, count: length(backups)}

            if age > @backup_max_age_seconds,
              do: fail("the newest backup is more than 26 hours old", details),
              else: ok(details)
        end
    end
  end

  # --- helpers ---

  defp select_one do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1") do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # Intervals as the workers themselves read them.
  defp worker_intervals do
    federation = Application.get_env(:baudrate, Baudrate.Federation, [])
    bots = Application.get_env(:baudrate, Baudrate.Bots, [])

    [
      delivery_worker: Keyword.get(federation, :delivery_poll_interval, 60_000),
      inbound_worker: Keyword.get(federation, :inbound_poll_interval, 30_000),
      feed_worker: bots[:bots_poll_interval] || 60_000,
      session_cleaner: Baudrate.Auth.SessionCleaner.interval_ms()
    ]
  end

  # A backup folder is named for the time it was started, in UTC.
  defp backup_time(path) do
    <<y::binary-4, mo::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2, "Z">> =
      Path.basename(path)

    {:ok, dt, 0} = DateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z")
    dt
  end

  defp configured_backup_dir do
    Application.get_env(:baudrate, __MODULE__, []) |> Keyword.get(:backup_dir)
  end

  defp federation_enabled?(opts) do
    Keyword.get_lazy(opts, :federation_enabled?, &Baudrate.Setup.federation_enabled?/0)
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp seconds_since(nil, _now), do: 0
  defp seconds_since(%DateTime{} = at, now), do: max(DateTime.diff(now, at, :second), 0)

  defp seconds_since(%NaiveDateTime{} = at, now),
    do: seconds_since(DateTime.from_naive!(at, "Etc/UTC"), now)

  defp ok(details), do: Map.put(details, :status, :ok)
  defp fail(reason, details \\ %{}), do: Map.merge(details, %{status: :fail, reason: reason})
  defp skipped(reason), do: %{status: :skipped, reason: reason}
end
