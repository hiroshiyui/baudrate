defmodule Baudrate.Sitemap.Generator do
  @moduledoc """
  GenServer that regenerates `sitemap.xml` daily at midnight UTC.

  On startup, generates the sitemap immediately (one-off catch-up), then
  schedules the next run at midnight. Each subsequent run schedules the
  next midnight.

  Disabled in test via `config :baudrate, sitemap_enabled: false`.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if enabled?() do
      send(self(), :generate)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:generate, state) do
    if enabled?() do
      case Baudrate.Sitemap.generate() do
        :ok ->
          Logger.info("sitemap.generator: sitemap.xml generated successfully")

        {:error, reason} ->
          Logger.error("sitemap.generator: failed to generate sitemap.xml: #{inspect(reason)}")
      end

      schedule_next_midnight()
    end

    {:noreply, state}
  end

  defp schedule_next_midnight do
    now = DateTime.utc_now()
    tomorrow = now |> DateTime.to_date() |> Date.add(1)
    midnight = DateTime.new!(tomorrow, ~T[00:00:00], "Etc/UTC")
    delay_ms = DateTime.diff(midnight, now, :millisecond)
    Process.send_after(self(), :generate, delay_ms)
  end

  defp enabled? do
    Application.get_env(:baudrate, :sitemap_enabled, true)
  end
end
