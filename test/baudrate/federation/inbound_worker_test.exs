defmodule Baudrate.Federation.InboundWorkerTest do
  # Drives the worker started by the application; its tasks reach the database
  # and the HTTP stub in shared mode.
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{Inbound, InboundActivity, InboundWorker, KeyStore, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    previous_async = Application.get_env(:baudrate, :federation_async)
    previous_config = Application.get_env(:baudrate, Baudrate.Federation, [])
    Application.put_env(:baudrate, :federation_async, :discard)
    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      Application.put_env(:baudrate, :federation_async, previous_async)
      Application.put_env(:baudrate, Baudrate.Federation, previous_config)
      Req.Test.set_req_test_to_private()
    end)

    %{user: create_user()}
  end

  describe "choosing what to process next" do
    test "the oldest pending activity of each actor, and none of a busy actor's", %{user: user} do
      a = create_remote_actor()
      b = create_remote_actor()

      a1 = stored_id(follow(a, user), a)
      _a2 = stored_id(follow(a, user), a)
      b1 = stored_id(follow(b, user), b)

      assert ids(InboundWorker.next_activities([], 10)) == [a1, b1]
      assert ids(InboundWorker.next_activities([a.id], 10)) == [b1]
      assert ids(InboundWorker.next_activities([], 1)) == [a1]
    end

    test "an activity waiting for a retry holds back the actor's later ones", %{user: user} do
      a = create_remote_actor()
      a1 = stored_id(follow(a, user), a)
      _a2 = stored_id(follow(a, user), a)

      later = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(r in InboundActivity, where: r.id == ^a1),
        set: [next_attempt_at: later]
      )

      assert InboundWorker.next_activities([], 10) == []
    end
  end

  describe "processing" do
    test "a wake-up processes stored activities, one actor's in the order they came",
         %{user: user} do
      a = create_remote_actor()
      local = Federation.actor_uri(:user, user.username)
      followed = follow(a, user)

      undo = %{
        "id" => "#{a.ap_id}/undo/#{uid()}",
        "type" => "Undo",
        "actor" => a.ap_id,
        "object" => followed
      }

      first = stored_id(followed, a)
      second = stored_id(undo, a)

      InboundWorker.wake()
      wait_until(fn -> Inbound.pending_count() == 0 end)
      wait_until_idle()

      assert Repo.get!(InboundActivity, first).status == "processed"
      assert Repo.get!(InboundActivity, second).status == "processed"
      # Follow, then Undo: had they run the other way round, the follow would stand.
      refute Federation.follower_exists?(local, a.ap_id)
    end

    test "processing past the deadline is killed and retried later", %{user: user} do
      put_federation_config(inbound_task_timeout: 100)

      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        Process.sleep(5_000)
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      a = create_remote_actor()
      _ = user

      # An `Update` of the actor refreshes it over HTTP, which the stub stalls.
      update = %{
        "id" => "#{a.ap_id}#update-#{uid()}",
        "type" => "Update",
        "actor" => a.ap_id,
        "object" => %{"id" => a.ap_id, "type" => "Person"}
      }

      id = stored_id(update, a)

      send(Process.whereis(InboundWorker), :poll)

      wait_until(fn -> Repo.get!(InboundActivity, id).last_error == ":timeout" end)
      wait_until_idle()

      row = Repo.get!(InboundActivity, id)
      assert row.status == "pending"
      assert row.attempts == 1
      assert row.next_attempt_at
    end
  end

  # --- Helpers ---

  defp ids(rows), do: Enum.map(rows, & &1.id)

  defp stored_id(activity, remote) do
    {:ok, %InboundActivity{id: id}} =
      Inbound.store(activity, Jason.encode!(activity), remote, :shared)

    id
  end

  defp follow(remote, user) do
    %{
      "id" => "#{remote.ap_id}/follows/#{uid()}",
      "type" => "Follow",
      "actor" => remote.ap_id,
      "object" => Federation.actor_uri(:user, user.username)
    }
  end

  defp put_federation_config(overrides) do
    config = Application.get_env(:baudrate, Baudrate.Federation, [])
    Application.put_env(:baudrate, Baudrate.Federation, Keyword.merge(config, overrides))
  end

  defp wait_until_idle do
    wait_until(fn -> :sys.get_state(InboundWorker).running == %{} end)
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

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "inworker_#{uid()}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    user
  end

  defp create_remote_actor do
    id = uid()

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/inworker-#{id}",
      username: "inworker_#{id}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/inworker-#{id}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp uid, do: System.unique_integer([:positive])
end
