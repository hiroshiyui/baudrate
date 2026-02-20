defmodule Baudrate.Auth.SessionCleaner do
  @moduledoc """
  GenServer that periodically purges expired sessions from the database.

  Runs `Auth.purge_expired_sessions/0` every hour (see `@interval`). Started
  as part of the application supervision tree (`Baudrate.Application`).

  The first cleanup is scheduled on `init/1`, so it runs one interval after
  the application boots — not immediately — to avoid slowing startup.
  """

  use GenServer

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
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @interval)
  end
end
