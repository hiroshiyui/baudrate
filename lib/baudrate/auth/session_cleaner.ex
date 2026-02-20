defmodule Baudrate.Auth.SessionCleaner do
  @moduledoc """
  Periodically purges expired sessions from the database.
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
