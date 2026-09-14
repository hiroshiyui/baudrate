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
    * Delivery jobs — purges delivered jobs older than 7 days and abandoned
      jobs older than 30 days
    * Media cache — evicts proxied remote images untouched for 30 days, then
      oldest-first until under the configured size ceiling
    * Data export requests — applies due `pending → ready → expired`
      transitions (sending ready notices), purges finished requests older
      than a year, and removes stale archive temp directories (also at boot)
    * Account moves — sends moves whose 24-hour cooling-off has passed, or
      marks them failed when the send-time re-check refuses them (ADR 0025)

  The first cleanup is scheduled on `init/1`, so it runs one interval after
  the application boots — not immediately — to avoid slowing startup.
  """

  use GenServer

  require Logger

  @interval :timer.hours(1)

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
    Baudrate.Auth.purge_expired_sessions()
    Baudrate.Auth.purge_old_login_attempts()
    cleanup_orphan_article_images()
    cleanup_orphan_comment_images()
    cleanup_orphan_reply_images()
    cleanup_delivery_jobs()
    refresh_stale_link_previews()
    purge_orphan_link_previews()
    purge_stale_media_cache()
    sweep_data_exports()
    sweep_account_moves()
    schedule_cleanup()
    {:noreply, state}
  end

  defp sweep_data_exports do
    Baudrate.DataPortability.sweep_transitions(:all)
    Baudrate.DataPortability.Archive.sweep_temp()
    count = Baudrate.DataPortability.purge_old_history()

    if count > 0 do
      Logger.info("session_cleaner.export_requests_purged: count=#{count}")
    end
  end

  # Sends account moves whose 24-hour cooling-off has passed (ADR 0025).
  defp sweep_account_moves do
    count = Baudrate.AccountMigration.sweep_due_moves()

    if count > 0 do
      Logger.info("session_cleaner.account_moves_processed: count=#{count}")
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
    count = Baudrate.Federation.Delivery.purge_completed_jobs()

    if count > 0 do
      Logger.info("session_cleaner.delivery_jobs_purged: count=#{count}")
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
