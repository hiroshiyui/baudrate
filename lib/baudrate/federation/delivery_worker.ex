defmodule Baudrate.Federation.DeliveryWorker do
  @moduledoc """
  Delivers queued `DeliveryJob`s, keeping up to `delivery_max_concurrency`
  (default 10) deliveries in flight.

  ## When it looks for jobs

    * **On commit.** `Delivery.enqueue/3` sends a PostgreSQL notification on
      `channel/0`, and this worker listens on a dedicated connection
      (`Postgrex.Notifications`, which reconnects on its own). PostgreSQL
      delivers a notification only when the enqueuing transaction commits, so
      a new activity starts on its way within moments of being saved — it used
      to wait up to a minute for the next poll.
    * **When a slot frees up**, if the last lookup filled every free slot (so
      there may be more waiting) or the finished job was a probe.
    * **Every `delivery_poll_interval`** (60 s, ±10% jitter) regardless: retries
      come due on the clock, and a notification can be missed while the
      listener reconnects.

  ## Deliveries

  Each delivery is a task under `Baudrate.Federation.TaskSupervisor`, not
  linked to this process. A task still running at the deadline (the HTTP
  request deadline plus 15 s) is killed and recorded as a failed attempt; a
  task that crashes is recorded too (`Delivery.record_interrupted/2`).

  ## Per-domain circuit breaker

  Jobs for a domain whose circuit has opened (`DeliveryCircuits`) are never
  selected as ordinary jobs. Once its `open_until` has passed, one of its jobs
  is sent as a probe, and at most one probe per domain is in flight. Probes
  take at most half the slots, so servers that are down cannot crowd out the
  ones that are up.

  Baudrate runs on one node (ADR 0033): jobs are selected without row locks,
  and a job already in flight here is excluded from the next lookup by id.
  Stopping the node mid-delivery leaves the job pending, so it is sent again
  after the restart (at-least-once; receivers deduplicate by activity id).
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Federation.{Delivery, DeliveryCircuit, DeliveryJob}

  @channel "baudrate_delivery"
  @wake_delay_ms 50

  @doc "The PostgreSQL notification channel `Delivery.enqueue/3` notifies."
  @spec channel() :: String.t()
  def channel, do: @channel

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      running: %{},
      more?: false,
      poll_timer: nil,
      wake_timer: nil,
      listener: start_listener()
    }

    {:ok, schedule_poll(state)}
  end

  @impl true
  def handle_info({:notification, _pid, _ref, @channel, _payload}, state) do
    # Coalesce a burst of commits into one lookup.
    if state.wake_timer do
      {:noreply, state}
    else
      {:noreply, %{state | wake_timer: Process.send_after(self(), :wake, @wake_delay_ms)}}
    end
  end

  def handle_info(:wake, state) do
    {:noreply, fill(%{state | wake_timer: nil})}
  end

  def handle_info(:poll, state) do
    state = state |> schedule_poll() |> fill()
    Baudrate.Health.Heartbeat.beat(:delivery_worker)
    {:noreply, state}
  end

  def handle_info({ref, _result}, %{running: running} = state)
      when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    {entry, state} = pop_running(state, ref)
    Process.cancel_timer(entry.deadline)
    {:noreply, after_delivery(state, entry)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: running} = state)
      when is_map_key(running, ref) do
    {entry, state} = pop_running(state, ref)
    Process.cancel_timer(entry.deadline)

    Logger.error(
      "federation.delivery_crashed: job_id=#{entry.job_id} reason=#{inspect(reason) |> String.slice(0, 500)}"
    )

    Delivery.record_interrupted(entry.job_id, {:crashed, reason})
    {:noreply, after_delivery(state, entry)}
  end

  def handle_info({:delivery_deadline, ref}, %{running: running} = state)
      when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    {entry, state} = pop_running(state, ref)
    Process.exit(entry.pid, :kill)

    Logger.warning("federation.delivery_timeout: job_id=#{entry.job_id} domain=#{entry.domain}")

    Delivery.record_interrupted(entry.job_id, :timeout)
    {:noreply, after_delivery(state, entry)}
  end

  def handle_info({:EXIT, pid, reason}, %{listener: pid} = state) do
    {:stop, {:listener_exited, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, _state) do
    Logger.info("federation.delivery_worker: shutting down (reason: #{inspect(reason)})")
    :ok
  end

  # --- Dispatch ---

  defp fill(state) do
    if Baudrate.Setup.federation_enabled?() do
      do_fill(state)
    else
      state
    end
  end

  defp do_fill(state) do
    free = max_concurrency() - map_size(state.running)

    if free <= 0 do
      %{state | more?: true}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      running_ids = Enum.map(state.running, fn {_ref, entry} -> entry.job_id end)

      probing =
        for {_ref, %{probe?: true, domain: domain}} <- state.running, do: domain

      probe_slots = min(free, max(div(max_concurrency(), 2), 1) - length(probing))

      probes =
        if probe_slots > 0, do: probe_jobs(now, running_ids, probing, probe_slots), else: []

      slots = free - length(probes)
      jobs = if slots > 0, do: ready_jobs(now, running_ids, slots), else: []

      if jobs != [] or probes != [] do
        Logger.info(
          "federation.delivery_worker: starting #{length(jobs)} jobs and #{length(probes)} probes"
        )
      end

      state = Enum.reduce(probes, state, &start(&2, &1, true))
      state = Enum.reduce(jobs, state, &start(&2, &1, false))
      %{state | more?: slots > 0 and length(jobs) == slots}
    end
  end

  defp after_delivery(state, entry) do
    if state.more? or entry.probe?, do: fill(state), else: state
  end

  defp start(state, job, probe?) do
    task =
      Task.Supervisor.async_nolink(Baudrate.Federation.TaskSupervisor, fn ->
        Delivery.deliver_one(job)
      end)

    deadline = Process.send_after(self(), {:delivery_deadline, task.ref}, task_deadline_ms())

    entry = %{
      job_id: job.id,
      domain: job.domain,
      probe?: probe?,
      pid: task.pid,
      deadline: deadline
    }

    %{state | running: Map.put(state.running, task.ref, entry)}
  end

  defp pop_running(state, ref) do
    {entry, running} = Map.pop(state.running, ref)
    {entry, %{state | running: running}}
  end

  # Waiting jobs that are due, excluding every domain whose circuit has opened.
  defp ready_jobs(now, running_ids, limit) do
    from(j in DeliveryJob,
      as: :job,
      where: j.id not in ^running_ids,
      where:
        not exists(
          from(c in DeliveryCircuit,
            where: c.domain == parent_as(:job).domain and c.trips > 0,
            select: 1
          )
        ),
      order_by: [asc: j.inserted_at, asc: j.id],
      limit: ^limit
    )
    |> due(now)
    |> Repo.all()
  end

  # The oldest due job of each domain whose circuit may be probed now.
  defp probe_jobs(now, running_ids, probing, limit) do
    candidates =
      from(j in DeliveryJob,
        join: c in DeliveryCircuit,
        on: c.domain == j.domain,
        where: c.trips > 0 and c.open_until <= ^now,
        where: j.id not in ^running_ids and j.domain not in ^probing,
        distinct: [asc: j.domain],
        order_by: [asc: j.id]
      )
      |> due(now)

    from(j in subquery(candidates), order_by: [asc: j.id], limit: ^limit)
    |> Repo.all()
  end

  defp due(query, now) do
    where(
      query,
      [j],
      (j.status == "pending" and is_nil(j.next_retry_at)) or
        (j.status in ["pending", "failed"] and j.next_retry_at <= ^now)
    )
  end

  # --- Timers and listener ---

  defp schedule_poll(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)

    interval = config(:delivery_poll_interval, 60_000)
    jitter = :rand.uniform(div(interval, 5)) - div(interval, 10)
    %{state | poll_timer: Process.send_after(self(), :poll, interval + jitter)}
  end

  # A dedicated connection outside the pool: LISTEN holds its connection. With
  # `sync_connect: false` and `auto_reconnect: true` a database outage delays
  # wake-ups instead of crashing the worker, and the channel is re-listened on
  # reconnect; the poll covers anything missed meanwhile.
  defp start_listener do
    if config(:delivery_listen, true) do
      opts =
        Repo.config()
        |> Keyword.drop([:pool, :pool_size, :ownership_timeout, :name])
        |> Keyword.merge(sync_connect: false, auto_reconnect: true)

      {:ok, pid} = Postgrex.Notifications.start_link(opts)
      {_ok_or_eventually, _ref} = Postgrex.Notifications.listen(pid, @channel)
      pid
    end
  end

  defp max_concurrency, do: config(:delivery_max_concurrency, 10)

  defp task_deadline_ms do
    config(:delivery_task_timeout, nil) || config(:http_request_timeout, 60_000) + 15_000
  end

  defp config(key, default) do
    Application.get_env(:baudrate, Baudrate.Federation, []) |> Keyword.get(key, default)
  end
end
