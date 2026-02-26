defmodule Baudrate.Federation.DeliveryWorker do
  @moduledoc """
  GenServer that polls the `delivery_jobs` table for pending and retryable
  jobs and processes them via `Delivery.deliver_one/1`.

  Follows the same pattern as `SessionCleaner`:
  - Polls every 60 seconds with ±10% jitter (configurable via `delivery_poll_interval`)
  - Processes up to 50 jobs per cycle (configurable via `delivery_batch_size`)
  - Delivers concurrently via `Task.Supervisor.async_stream_nolink`
    (configurable via `delivery_max_concurrency`, default 10)
  - Skips jobs targeting blocked domains
  - Graceful shutdown: sets `shutting_down` flag, skips new polls, and lets
    in-flight tasks finish via the supervised task supervisor
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
    Process.flag(:trap_exit, true)
    schedule_poll()
    {:ok, %{shutting_down: false}}
  end

  @impl true
  def handle_info(:poll, %{shutting_down: true} = state) do
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    if Baudrate.Setup.federation_enabled?() do
      process_batch()
    end

    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("federation.delivery_worker: shutting down (reason: #{inspect(reason)})")
    :ok
  end

  defp schedule_poll do
    config = Application.get_env(:baudrate, Baudrate.Federation, [])
    interval = config[:delivery_poll_interval] || 60_000
    jitter = :rand.uniform(div(interval, 5)) - div(interval, 10)
    Process.send_after(self(), :poll, interval + jitter)
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

    max_concurrency = config[:delivery_max_concurrency] || 10
    http_receive_timeout = config[:http_receive_timeout] || 30_000
    task_timeout = http_receive_timeout + 15_000

    Baudrate.Federation.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      jobs,
      fn job -> Delivery.deliver_one(job) end,
      max_concurrency: max_concurrency,
      timeout: task_timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()
  end
end
