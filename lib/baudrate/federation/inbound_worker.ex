defmodule Baudrate.Federation.InboundWorker do
  @moduledoc """
  Processes stored inbound activities (`Federation.Inbound`) outside the HTTP
  request, with at most `inbound_max_concurrency` (default 4) at a time.

  Processing an activity can take a while — resolving an unknown actor, walking
  a reply chain, fetching an announced object — and it used to happen while the
  sender's request waited, holding a web process and database connections. A
  remote instance sending many such activities could tie up the server for
  everyone. Now the request only stores the activity, and this worker bounds
  how much of that work runs at once. The limit is kept below the database
  pool size so web requests always find a connection.

  ## Order

  Activities from one remote actor are processed one at a time, oldest first:
  a `Create` and the `Delete` sent right after it must not run the other way
  round. The worker takes the oldest pending activity of each actor that has
  nothing in flight, so a single busy actor also cannot take every slot. If
  that oldest activity is waiting to be retried after a crash, the actor's
  later activities wait behind it (for at most a few minutes).

  ## When it runs

    * `wake/0`, called by the inbox as soon as an activity is stored;
    * whenever a processing task finishes;
    * every `inbound_poll_interval` (30 s), for retries coming due and for
      activities left pending by a restart.

  A task still running after `inbound_task_timeout` (5 minutes) is killed and
  counted as a failed attempt (`Inbound.record_interrupted/2`).
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Baudrate.Federation.{Inbound, InboundActivity}
  alias Baudrate.Repo

  @wake_delay_ms 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Asks the worker to look for pending activities. Does nothing when the worker
  is not running; the next poll picks the activity up.
  """
  @spec wake() :: :ok
  def wake do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, :wake)
    end

    :ok
  end

  @impl true
  def init(_opts) do
    {:ok, schedule_poll(%{running: %{}, poll_timer: nil, wake_timer: nil})}
  end

  @impl true
  def handle_info(:wake, %{wake_timer: nil} = state) do
    {:noreply, %{state | wake_timer: Process.send_after(self(), :fill, @wake_delay_ms)}}
  end

  def handle_info(:wake, state), do: {:noreply, state}

  def handle_info(:fill, state) do
    {:noreply, fill(%{state | wake_timer: nil})}
  end

  def handle_info(:poll, state) do
    {:noreply, state |> schedule_poll() |> fill()}
  end

  def handle_info({ref, _outcome}, %{running: running} = state)
      when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    {entry, state} = pop_running(state, ref)
    Process.cancel_timer(entry.deadline)
    {:noreply, fill(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: running} = state)
      when is_map_key(running, ref) do
    {entry, state} = pop_running(state, ref)
    Process.cancel_timer(entry.deadline)

    Logger.error(
      "federation.inbound_crashed: id=#{entry.id} reason=#{inspect(reason) |> String.slice(0, 500)}"
    )

    Inbound.record_interrupted(entry.id, {:crashed, reason})
    {:noreply, fill(state)}
  end

  def handle_info({:inbound_deadline, ref}, %{running: running} = state)
      when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    {entry, state} = pop_running(state, ref)
    Process.exit(entry.pid, :kill)

    Logger.warning("federation.inbound_timeout: id=#{entry.id}")
    Inbound.record_interrupted(entry.id, :timeout)
    {:noreply, fill(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Dispatch ---

  defp fill(state) do
    free = config(:inbound_max_concurrency, 4) - map_size(state.running)

    if free > 0 and Baudrate.Setup.federation_enabled?() do
      busy = Enum.map(state.running, fn {_ref, entry} -> entry.actor_id end)

      busy
      |> next_activities(free)
      |> Enum.reduce(state, &start(&2, &1))
    else
      state
    end
  end

  @doc false
  # The oldest pending activity of each actor with nothing in flight (`busy`),
  # taken only if it is due. Public for its test.
  def next_activities(busy, limit) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    heads =
      from(a in InboundActivity,
        where: a.status == "pending" and a.remote_actor_id not in ^busy,
        distinct: [asc: a.remote_actor_id],
        order_by: [asc: a.id],
        select: %{
          id: a.id,
          remote_actor_id: a.remote_actor_id,
          next_attempt_at: a.next_attempt_at
        }
      )

    from(h in subquery(heads),
      where: is_nil(h.next_attempt_at) or h.next_attempt_at <= ^now,
      order_by: [asc: h.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp start(state, %{id: id, remote_actor_id: actor_id}) do
    task =
      Task.Supervisor.async_nolink(Baudrate.Federation.TaskSupervisor, fn ->
        Inbound.process(id)
      end)

    deadline =
      Process.send_after(
        self(),
        {:inbound_deadline, task.ref},
        config(:inbound_task_timeout, 300_000)
      )

    entry = %{id: id, actor_id: actor_id, pid: task.pid, deadline: deadline}
    %{state | running: Map.put(state.running, task.ref, entry)}
  end

  defp pop_running(state, ref) do
    {entry, running} = Map.pop(state.running, ref)
    {entry, %{state | running: running}}
  end

  defp schedule_poll(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    timer = Process.send_after(self(), :poll, config(:inbound_poll_interval, 30_000))
    %{state | poll_timer: timer}
  end

  defp config(key, default) do
    Application.get_env(:baudrate, Baudrate.Federation, []) |> Keyword.get(key, default)
  end
end
