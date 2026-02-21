defmodule Baudrate.Federation.DeliveryWorker do
  @moduledoc """
  GenServer that polls the `delivery_jobs` table for pending and retryable
  jobs and processes them via `Delivery.deliver_one/1`.

  Follows the same pattern as `SessionCleaner`:
  - Polls every 60 seconds (configurable via `delivery_poll_interval`)
  - Processes up to 50 jobs per cycle (configurable via `delivery_batch_size`)
  - Skips jobs targeting blocked domains
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Federation.{Delivery, DeliveryJob}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    if Baudrate.Setup.federation_enabled?() do
      process_batch()
    end

    schedule_poll()
    {:noreply, state}
  end

  defp schedule_poll do
    config = Application.get_env(:baudrate, Baudrate.Federation, [])
    interval = config[:delivery_poll_interval] || 60_000
    Process.send_after(self(), :poll, interval)
  end

  defp process_batch do
    config = Application.get_env(:baudrate, Baudrate.Federation, [])
    batch_size = config[:delivery_batch_size] || 50
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    jobs =
      from(j in DeliveryJob,
        where:
          (j.status == "pending" and is_nil(j.next_retry_at)) or
            (j.status in ["pending", "failed"] and j.next_retry_at <= ^now),
        order_by: [asc: j.inserted_at],
        limit: ^batch_size
      )
      |> Repo.all()

    if jobs != [] do
      Logger.info("federation.delivery_worker: processing #{length(jobs)} jobs")
    end

    Enum.each(jobs, fn job ->
      Delivery.deliver_one(job)
    end)
  end
end
