defmodule Baudrate.Auth.SessionCleaner do
  @moduledoc """
  GenServer that periodically purges expired sessions, old login attempts,
  and orphan article images.

  Runs every hour (see `@interval`). Started as part of the application
  supervision tree (`Baudrate.Application`).

  Cleanup tasks:
    * `Auth.purge_expired_sessions/0` — removes expired user sessions
    * `Auth.purge_old_login_attempts/0` — removes login attempts older than 7 days
    * Orphan article images — deletes images uploaded during article composition
      but never associated with an article (older than 24 hours)
    * Orphan comment images — deletes images uploaded during comment composition
      but never associated with a comment (older than 24 hours)
    * Orphan reply images — deletes images uploaded during feed reply composition
      but never associated with a reply (older than 24 hours)
    * Delivery jobs — abandons jobs still waiting after 7 days (held back by
      an open circuit), purges delivered jobs older than 7 days and abandoned
      jobs older than 30 days, and removes circuit breaker rows not updated
      for 30 days
    * Inbound activities — deletes processed, rejected and failed rows older
      than 7 days (`Federation.Inbound.purge_finished/0`)
    * Media cache — evicts proxied remote images untouched for 30 days, then
      oldest-first until under the configured size ceiling
    * Data export requests — applies due `pending → ready → expired`
      transitions (sending ready notices), purges finished requests older
      than a year, and removes stale archive temp directories (also at boot)
    * Account moves — sends moves whose 24-hour cooling-off has passed, or
      marks them failed when the send-time re-check refuses them (ADR 0025)
    * Notifications — deletes notifications older than 90 days
      (`Notification.cleanup_old_notifications/1`)

  The first cleanup is scheduled on `init/1`, so it runs one interval after
  the application boots — not immediately — to avoid slowing startup.
  """

  use GenServer

  require Logger

  @interval :timer.hours(1)
  @notification_retention_days 90

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Archive staging directories left behind by a crash: remove at boot.
    Baudrate.DataPortability.Archive.sweep_temp()
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Each step runs on its own: a step that raises is logged and the rest
    # still run. A crash used to abort the whole run, so a single link preview
    # refetch failing every hour silently skipped the export and account move
    # sweeps and every purge after it.
    [
      purge_expired_sessions: &Baudrate.Auth.purge_expired_sessions/0,
      purge_old_login_attempts: &Baudrate.Auth.purge_old_login_attempts/0,
      cleanup_orphan_article_images: &cleanup_orphan_article_images/0,
      cleanup_orphan_comment_images: &cleanup_orphan_comment_images/0,
      cleanup_orphan_reply_images: &cleanup_orphan_reply_images/0,
      cleanup_delivery_jobs: &cleanup_delivery_jobs/0,
      purge_inbound_activities: &purge_inbound_activities/0,
      refresh_stale_link_previews: &refresh_stale_link_previews/0,
      purge_orphan_link_previews: &purge_orphan_link_previews/0,
      purge_stale_media_cache: &purge_stale_media_cache/0,
      sweep_data_exports: &sweep_data_exports/0,
      sweep_account_moves: &sweep_account_moves/0,
      cleanup_old_notifications: &cleanup_old_notifications/0,
      notify_ended_sanctions: &notify_ended_sanctions/0,
      purge_closed_report_evidence: &Baudrate.Moderation.purge_closed_report_evidence/0
    ]
    |> Enum.each(fn {name, step} -> run_step(name, step) end)

    Baudrate.Health.Heartbeat.beat(:session_cleaner)
    schedule_cleanup()
    {:noreply, state}
  end

  @doc "How often the cleanup runs, in milliseconds."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @interval

  @doc false
  # Runs one cleanup step, logging instead of crashing when it raises or exits.
  def run_step(name, step) do
    step.()
    :ok
  rescue
    exception ->
      Logger.error(
        "session_cleaner.step_failed: step=#{name} " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :error
  catch
    kind, reason ->
      Logger.error(
        "session_cleaner.step_failed: step=#{name} " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      :error
  end

  defp sweep_data_exports do
    Baudrate.DataPortability.sweep_transitions(:all)
    Baudrate.DataPortability.Archive.sweep_temp()
    count = Baudrate.DataPortability.purge_old_history()

    if count > 0 do
      Logger.info("session_cleaner.export_requests_purged: count=#{count}")
    end
  end

  # Tells members whose silence or suspension has just run out. Enforcement
  # already stopped by the clock; this run only delivers the courtesy notice,
  # so missing it costs nothing (ADR 0029).
  defp notify_ended_sanctions do
    count = Baudrate.Auth.notify_ended_sanctions()

    if count > 0 do
      Logger.info("session_cleaner.sanctions_ended: count=#{count}")
    end
  end

  # Sends account moves whose 24-hour cooling-off has passed (ADR 0025).
  defp sweep_account_moves do
    count = Baudrate.AccountMigration.sweep_due_moves()

    if count > 0 do
      Logger.info("session_cleaner.account_moves_processed: count=#{count}")
    end
  end

  defp cleanup_old_notifications do
    {count, _} = Baudrate.Notification.cleanup_old_notifications(@notification_retention_days)

    if count > 0 do
      Logger.info("session_cleaner.notifications_purged: count=#{count}")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @interval)
  end

  # Eviction is non-destructive: an evicted image is simply re-fetched the next
  # time someone views it.
  defp purge_stale_media_cache do
    count = Baudrate.Media.Cache.purge_stale()

    if count > 0 do
      Logger.info("session_cleaner.media_cache_purged: count=#{count}")
    end
  end

  defp cleanup_delivery_jobs do
    expired = Baudrate.Federation.Delivery.expire_held_jobs()

    if expired > 0 do
      Logger.warning("session_cleaner.delivery_jobs_expired: count=#{expired}")
    end

    count = Baudrate.Federation.Delivery.purge_completed_jobs()

    if count > 0 do
      Logger.info("session_cleaner.delivery_jobs_purged: count=#{count}")
    end

    circuits = Baudrate.Federation.DeliveryCircuits.purge_idle()

    if circuits > 0 do
      Logger.info("session_cleaner.delivery_circuits_purged: count=#{circuits}")
    end
  end

  defp purge_inbound_activities do
    count = Baudrate.Federation.Inbound.purge_finished()

    if count > 0 do
      Logger.info("session_cleaner.inbound_activities_purged: count=#{count}")
    end
  end

  defp refresh_stale_link_previews do
    count = Baudrate.Content.refresh_stale_link_previews()

    if count > 0 do
      Logger.info("session_cleaner.link_previews_refreshed: count=#{count}")
    end
  end

  defp purge_orphan_link_previews do
    paths = Baudrate.Content.purge_stale_link_previews()

    for path <- paths do
      abs_path =
        Application.app_dir(:baudrate, Path.join(["priv", "static", path]))

      case File.rm(abs_path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> Logger.warning("Failed to delete preview image #{path}: #{reason}")
      end
    end
  end

  defp cleanup_orphan_article_images do
    cutoff = DateTime.utc_now() |> DateTime.add(-24, :hour)
    paths = Baudrate.Content.delete_orphan_article_images(cutoff)

    for path <- paths do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> Logger.warning("Failed to delete orphan image #{path}: #{reason}")
      end
    end
  end

  defp cleanup_orphan_comment_images do
    cutoff = DateTime.utc_now() |> DateTime.add(-24, :hour)
    paths = Baudrate.Content.delete_orphan_comment_images(cutoff)

    for path <- paths do
      case File.rm(path) do
        :ok ->
          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to delete orphan comment image #{path}: #{reason}")
      end
    end
  end

  defp cleanup_orphan_reply_images do
    cutoff = DateTime.utc_now() |> DateTime.add(-24, :hour)
    paths = Baudrate.Federation.delete_orphan_reply_images(cutoff)

    for path <- paths do
      case File.rm(path) do
        :ok ->
          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to delete orphan reply image #{path}: #{reason}")
      end
    end
  end
end
