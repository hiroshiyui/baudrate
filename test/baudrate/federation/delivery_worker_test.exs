defmodule Baudrate.Federation.DeliveryWorkerTest do
  # Drives the worker started by the application, so it cannot run alongside
  # other tests: its tasks reach the database and the HTTP stub in shared mode.
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{DeliveryCircuit, DeliveryJob, DeliveryWorker, KeyStore}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    original = Application.get_env(:baudrate, Baudrate.Federation, [])
    Req.Test.set_req_test_to_shared()
    stub_inbox(202)

    on_exit(fn ->
      Application.put_env(:baudrate, Baudrate.Federation, original)
      Req.Test.set_req_test_to_private()
    end)

    %{actor_uri: local_actor_uri()}
  end

  describe "startup" do
    test "runs and listens for notifications on its own connection" do
      state = :sys.get_state(DeliveryWorker)

      assert is_pid(state.listener)
      assert Process.alive?(state.listener)
    end
  end

  describe "a poll" do
    test "delivers due pending jobs", %{actor_uri: actor_uri} do
      job = insert_job(actor_uri, "https://remote.example/inbox")

      poll_and_wait()

      assert %{status: "delivered", attempts: 1} = Repo.get!(DeliveryJob, job.id)
    end

    test "leaves jobs that are not due, delivered or abandoned alone", %{actor_uri: actor_uri} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      retry_later =
        insert_job(actor_uri, "https://remote.example/inbox",
          status: "failed",
          attempts: 1,
          next_retry_at: future
        )

      delivered = insert_job(actor_uri, "https://remote.example/inbox", status: "delivered")
      abandoned = insert_job(actor_uri, "https://remote.example/inbox", status: "abandoned")

      poll_and_wait()

      assert %{status: "failed", attempts: 1} = Repo.get!(DeliveryJob, retry_later.id)
      assert %{status: "delivered", attempts: 0} = Repo.get!(DeliveryJob, delivered.id)
      assert %{status: "abandoned", attempts: 0} = Repo.get!(DeliveryJob, abandoned.id)
    end

    test "keeps no more deliveries in flight than the concurrency limit", %{actor_uri: actor_uri} do
      put_federation_config(delivery_max_concurrency: 2)
      test_pid = self()

      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        send(test_pid, {:delivering, self()})

        receive do
          :release -> Plug.Conn.send_resp(conn, 202, "")
        end
      end)

      jobs = for i <- 1..3, do: insert_job(actor_uri, "https://host#{i}.example/inbox")

      send(Process.whereis(DeliveryWorker), :poll)
      assert_receive {:delivering, first}, 2_000
      assert_receive {:delivering, second}, 2_000
      refute_receive {:delivering, _}, 200
      assert map_size(:sys.get_state(DeliveryWorker).running) == 2

      # Freeing a slot starts the third job without waiting for the next poll.
      send(first, :release)
      assert_receive {:delivering, third}, 2_000
      send(second, :release)
      send(third, :release)
      wait_until_idle()

      assert Enum.all?(jobs, &(Repo.get!(DeliveryJob, &1.id).status == "delivered"))
    end
  end

  describe "waking up" do
    test "a notification starts delivery without waiting for the poll", %{actor_uri: actor_uri} do
      job = insert_job(actor_uri, "https://remote.example/inbox")

      send(
        Process.whereis(DeliveryWorker),
        {:notification, self(), make_ref(), DeliveryWorker.channel(), ""}
      )

      wait_until(fn -> Repo.get!(DeliveryJob, job.id).status == "delivered" end)
      wait_until_idle()
    end

    # End to end through PostgreSQL: a NOTIFY committed on another connection
    # reaches the worker's listener. (Inside the test sandbox nothing commits,
    # which is why enqueueing in a test does not wake the worker.)
    test "a committed NOTIFY on the channel reaches the worker", %{actor_uri: actor_uri} do
      job = insert_job(actor_uri, "https://remote.example/inbox")

      config = Repo.config() |> Keyword.drop([:pool, :pool_size, :ownership_timeout])
      {:ok, conn} = Postgrex.start_link(config)

      try do
        wait_until(fn ->
          Postgrex.query!(conn, "SELECT pg_notify($1, '')", [DeliveryWorker.channel()])
          Repo.get!(DeliveryJob, job.id).status == "delivered"
        end)
      after
        GenServer.stop(conn)
      end

      wait_until_idle()
    end
  end

  describe "deadlines" do
    test "a delivery still running at the deadline is killed and counts as a failed attempt",
         %{actor_uri: actor_uri} do
      put_federation_config(delivery_task_timeout: 100)

      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        Process.sleep(5_000)
        Plug.Conn.send_resp(conn, 202, "")
      end)

      job = insert_job(actor_uri, "https://slow.example/inbox")

      poll_and_wait()

      updated = Repo.get!(DeliveryJob, job.id)
      assert updated.status == "failed"
      assert updated.attempts == 1
      assert updated.last_error == ":timeout"
      assert updated.next_retry_at

      assert %DeliveryCircuit{failures: 1} = Repo.get(DeliveryCircuit, "slow.example")
    end
  end

  describe "circuit breaker" do
    test "a domain whose circuit is open is skipped while others are delivered",
         %{actor_uri: actor_uri} do
      open_circuit("down.example", in_seconds: 600)
      held = insert_job(actor_uri, "https://down.example/inbox")
      healthy = insert_job(actor_uri, "https://up.example/inbox")

      poll_and_wait()

      assert %{status: "pending", attempts: 0} = Repo.get!(DeliveryJob, held.id)
      assert %{status: "delivered"} = Repo.get!(DeliveryJob, healthy.id)
    end

    test "once the circuit may be probed, one job goes first and a success releases the rest",
         %{actor_uri: actor_uri} do
      open_circuit("back.example", in_seconds: -1)
      test_pid = self()

      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        send(test_pid, {:delivering, self()})

        receive do
          :release -> Plug.Conn.send_resp(conn, 202, "")
        end
      end)

      [first | rest] = for _ <- 1..3, do: insert_job(actor_uri, "https://back.example/inbox")

      send(Process.whereis(DeliveryWorker), :poll)
      assert_receive {:delivering, probe}, 2_000
      refute_receive {:delivering, _}, 200

      assert [%{probe?: true, job_id: job_id}] =
               Map.values(:sys.get_state(DeliveryWorker).running)

      assert job_id == first.id

      # The probe succeeds: the circuit closes and the held jobs go out.
      send(probe, :release)
      assert_receive {:delivering, a}, 2_000
      assert_receive {:delivering, b}, 2_000
      send(a, :release)
      send(b, :release)
      wait_until_idle()

      refute Repo.get(DeliveryCircuit, "back.example")
      assert Enum.all?([first | rest], &(Repo.get!(DeliveryJob, &1.id).status == "delivered"))
    end

    test "a failed probe reopens the circuit for longer and holds the rest back",
         %{actor_uri: actor_uri} do
      open_circuit("still-down.example", in_seconds: -1)
      stub_inbox(503)
      jobs = for _ <- 1..2, do: insert_job(actor_uri, "https://still-down.example/inbox")

      poll_and_wait()

      circuit = Repo.get!(DeliveryCircuit, "still-down.example")
      assert circuit.trips == 2
      assert DateTime.diff(circuit.open_until, DateTime.utc_now()) > 1500

      assert jobs |> Enum.map(&Repo.get!(DeliveryJob, &1.id).attempts) |> Enum.sort() == [0, 1]
    end
  end

  # --- Helpers ---

  defp local_actor_uri do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "worker_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    Federation.actor_uri(:user, user.username)
  end

  defp insert_job(actor_uri, inbox_url, overrides \\ []) do
    uid = System.unique_integer([:positive])

    %DeliveryJob{}
    |> DeliveryJob.create_changeset(%{
      activity_json: ~s({"id":"#{actor_uri}#test-#{uid}","type":"Create"}),
      inbox_url: inbox_url,
      actor_uri: actor_uri
    })
    |> Ecto.Changeset.change(Map.new(overrides))
    |> Repo.insert!()
  end

  defp open_circuit(domain, in_seconds: seconds) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%DeliveryCircuit{
      domain: domain,
      failures: 5,
      trips: 1,
      open_until: DateTime.add(now, seconds, :second)
    })
  end

  defp stub_inbox(status) do
    Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  defp put_federation_config(overrides) do
    config = Application.get_env(:baudrate, Baudrate.Federation, [])
    Application.put_env(:baudrate, Baudrate.Federation, Keyword.merge(config, overrides))
  end

  defp poll_and_wait do
    send(Process.whereis(DeliveryWorker), :poll)
    wait_until_idle()
  end

  # `:sys.get_state/1` returns once the worker has handled every message ahead
  # of it, including the poll that started the deliveries.
  defp wait_until_idle do
    wait_until(fn -> :sys.get_state(DeliveryWorker).running == %{} end)
  end

  defp wait_until(fun, deadline_ms \\ 5_000) do
    cond do
      fun.() ->
        :ok

      deadline_ms <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        wait_until(fun, deadline_ms - 20)
    end
  end
end
