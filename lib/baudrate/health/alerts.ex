defmodule Baudrate.Health.Alerts do
  @moduledoc """
  Turns a failing health check into something a person actually receives
  (Phase 2A, ADR 0044).

  `Baudrate.Health` has always known when a backup is stale, a queue is stuck,
  a worker is dead, the disk is full or an encryption key is missing. Nothing
  told anyone: the report answers `503` and `scripts/pull-backups.sh` exits
  non-zero, and both wait for a monitor the operator has to build. ADR 0035
  recorded that as a deliberate gap ("Baudrate does not notify") on the grounds
  that the instance had no email (D3), no push channel and no stored
  credentials. Two of those three stopped being true when Web Push shipped in
  Phase 2G, and the third never applied to the instance's own admins.

  So this runs hourly from `Baudrate.Auth.SessionCleaner` and notifies every
  admin — in-app, and by Web Push for admins who subscribed, since
  `Notification.create_notification/1` pushes on its own.

  ## Why this cannot live inside the backup

  An alert raised by the backup task can only report a run that **failed**. It
  can never report a run that **never happened** — a masked timer, a disabled
  unit, a server that was down at the scheduled time — and that is the failure
  this is for: a backup that silently stopped looks exactly like a backup that
  was never needed. So the alert is driven by a periodic check of the report,
  which measures the age of what is on disk and therefore notices absence.

  ## Repeating without nagging

  An alert nobody can switch off has to be quiet enough to stay believable:

    * A failing set must persist for two consecutive polls before anything is
      sent, so a delivery queue that is briefly behind at the moment we look
      does not wake anyone. A set that *changes* restarts that count, because
      the new member of it has not been seen twice yet.
    * While the same set keeps failing, it is repeated once a day, not hourly.
    * Recovery is announced once, and only if a failure was announced first.

  The "have we said this already" half of that state is the notification rows
  themselves — nothing else has to be stored, and it survives a restart, so a
  deploy does not re-announce a week-old problem. The consecutive-poll counter
  is the one piece held in memory, because losing it delays an alert by an hour
  rather than repeating one.

  ## What it does not cover

  An instance that is down notifies nobody: this runs inside the application it
  reports on, and the `database` check cannot both fail and be written to.
  That is a monitor's job, and `doc/sysop.md` still documents one. This closes
  "backups stopped and nobody noticed", not "the server is gone".
  """

  import Ecto.Query

  require Logger

  alias Baudrate.Health
  alias Baudrate.Notification.{Hooks, Notification}
  alias Baudrate.Repo

  # Polls a failing set must survive before anyone is told. The poll is hourly,
  # so this is "still wrong an hour later".
  @min_consecutive 2

  # How often the same unchanged failing set is repeated.
  @repeat_seconds 24 * 3600

  @alert_type "health_alert"
  @recovered_type "health_recovered"

  @type state :: %{checks: [String.t()], consecutive: non_neg_integer()}

  @doc "The state to start from, before any poll has run."
  @spec initial_state() :: state()
  def initial_state, do: %{checks: [], consecutive: 0}

  @doc """
  Runs the health report, decides whether to tell the admins, and returns the
  state for the next poll.

  Options are passed through to `Baudrate.Health.report/1`, plus `:now` and
  `:report` for tests.
  """
  @spec run(state(), keyword()) :: state()
  def run(state, opts \\ []) do
    state = normalize(state)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    report =
      Keyword.get_lazy(opts, :report, fn ->
        Health.report(Keyword.take(opts, [:only, :timeout_ms]))
      end)

    case failing_checks(report) do
      [] -> announce_recovery()
      failing -> announce_failure(state, failing, report, now)
    end
  end

  # Names of the checks that are failing, sorted so the set compares by value.
  # `:skipped` is not a failure: a check that does not apply to this instance
  # has nothing to say.
  defp failing_checks(report) do
    report.checks
    |> Enum.filter(fn {_name, check} -> check.status == :fail end)
    |> Enum.map(fn {name, _check} -> to_string(name) end)
    |> Enum.sort()
  end

  defp announce_failure(state, failing, report, now) do
    consecutive = if failing == state.checks, do: state.consecutive + 1, else: 1

    if consecutive >= @min_consecutive and due?(failing, now) do
      Logger.warning("health.alert: #{reasons(report, failing)}")
      Hooks.notify_health_alert(failing)
    end

    %{checks: failing, consecutive: consecutive}
  end

  defp announce_recovery do
    case last_notice() do
      %{type: @alert_type} ->
        Logger.info("health.recovered")
        Hooks.notify_health_recovered()

      _ ->
        :ok
    end

    initial_state()
  end

  # Whether this set is due to be announced: never announced, announced as a
  # different set, already announced but a day ago, or the last thing we said
  # was that everything had recovered.
  defp due?(failing, now) do
    case last_notice() do
      nil ->
        true

      %{type: @recovered_type} ->
        true

      %{type: @alert_type, data: data, inserted_at: at} ->
        Map.get(data, "checks") != failing or DateTime.diff(now, at) >= @repeat_seconds
    end
  end

  # The newest thing we told the admins about the instance's health. Admins
  # share it: the alert goes to all of them at once, so any row answers "have
  # we said this already".
  defp last_notice do
    from(n in Notification,
      where: n.type in [@alert_type, @recovered_type],
      order_by: [desc: n.inserted_at, desc: n.id],
      limit: 1,
      select: %{type: n.type, data: n.data, inserted_at: n.inserted_at}
    )
    |> Repo.one()
  end

  # For the log only. The report's reasons are fixed strings with no content,
  # account names or exception text in them (ADR 0035), which is why they are
  # safe to write to the journal — and why the notification carries only the
  # check names and sends the reader to the report.
  defp reasons(report, failing) do
    Enum.map_join(failing, " ", fn name ->
      check = Enum.find_value(report.checks, fn {n, c} -> if to_string(n) == name, do: c end)
      "#{name}=#{inspect(check[:reason])}"
    end)
  end

  defp normalize(%{checks: checks, consecutive: n}) when is_list(checks) and is_integer(n),
    do: %{checks: checks, consecutive: n}

  defp normalize(_), do: initial_state()
end
