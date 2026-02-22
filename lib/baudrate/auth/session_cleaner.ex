defmodule Baudrate.Auth.SessionCleaner do
  @moduledoc """
  GenServer that periodically purges expired sessions and orphan article images.

  Runs every hour (see `@interval`). Started as part of the application
  supervision tree (`Baudrate.Application`).

  Cleanup tasks:
    * `Auth.purge_expired_sessions/0` — removes expired user sessions
    * Orphan article images — deletes images uploaded during article composition
      but never associated with an article (older than 24 hours)

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
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    Baudrate.Auth.purge_expired_sessions()
    cleanup_orphan_article_images()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @interval)
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
end
