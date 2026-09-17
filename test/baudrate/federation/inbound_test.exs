defmodule Baudrate.Federation.InboundTest do
  # Switches `:federation_async` for some tests, which is global.
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{Inbound, InboundActivity, KeyStore, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    %{user: create_user(), remote: create_remote_actor()}
  end

  describe "accept/4" do
    test "stores the activity and, in tests, processes it at once", %{user: user, remote: remote} do
      activity = follow(remote, user)

      assert :ok = Inbound.accept(activity, Jason.encode!(activity), remote, {:user, user})

      assert Federation.follower_exists?(Federation.actor_uri(:user, user.username), remote.ap_id)

      assert %InboundActivity{
               status: "processed",
               activity_type: "Follow",
               activity_json: nil,
               attempts: 1,
               target_type: "user"
             } = row = Repo.one!(InboundActivity)

      assert row.target_id == user.id
      assert row.activity_id == activity["id"]
      assert row.processed_at
    end

    test "refuses an activity that fails admission, and stores nothing",
         %{user: user, remote: remote} do
      impostor = %{follow(remote, user) | "actor" => "https://remote.example/users/someone-else"}

      assert {:error, :activity_id_origin_mismatch} =
               Inbound.accept(
                 %{impostor | "id" => "https://elsewhere.example/follow/1"},
                 "{}",
                 remote,
                 :shared
               )

      assert {:error, :actor_mismatch} = Inbound.accept(impostor, "{}", remote, :shared)
      assert Repo.aggregate(InboundActivity, :count) == 0
    end

    test "a redelivered activity is stored once", %{user: user, remote: remote} do
      discard_tasks()
      activity = follow(remote, user)
      body = Jason.encode!(activity)

      assert :ok = Inbound.accept(activity, body, remote, :shared)
      assert :ok = Inbound.accept(activity, body, remote, {:user, user})

      assert [%InboundActivity{status: "pending", target_type: "shared"}] =
               Repo.all(InboundActivity)
    end

    test "the same id from another actor on the server is stored separately",
         %{user: user, remote: remote} do
      discard_tasks()
      other = create_remote_actor()
      activity = follow(remote, user)

      assert :ok = Inbound.accept(activity, Jason.encode!(activity), remote, :shared)

      from_other = %{activity | "actor" => other.ap_id}
      assert :ok = Inbound.accept(from_other, Jason.encode!(from_other), other, :shared)

      assert Repo.aggregate(InboundActivity, :count) == 2
    end
  end

  describe "process/1" do
    setup do
      discard_tasks()
      :ok
    end

    test "a refused activity is marked rejected with its reason, and its body dropped",
         %{remote: remote} do
      activity = %{
        "id" => "#{remote.ap_id}/follows/nobody",
        "type" => "Follow",
        "actor" => remote.ap_id,
        "object" => "https://local.example/ap/users/does-not-exist"
      }

      id = stored_id(activity, remote, :shared)

      assert Inbound.process(id) == :rejected

      assert %InboundActivity{status: "rejected", last_error: ":not_found", activity_json: nil} =
               Repo.get!(InboundActivity, id)
    end

    test "admission is checked again: a domain blocked after the activity arrived",
         %{user: user} do
      remote = create_remote_actor(domain: "blocked-later-#{uid()}.example")
      id = stored_id(follow(remote, user), remote, :shared)

      {:ok, _} = Federation.DomainBlocks.block_domain(remote.domain)

      assert Inbound.process(id) == :rejected
      assert %InboundActivity{last_error: ":domain_blocked"} = Repo.get!(InboundActivity, id)
      refute Federation.follower_exists?(Federation.actor_uri(:user, user.username), remote.ap_id)
    end

    test "a board that stopped federating is no longer a target", %{remote: remote} do
      board =
        Repo.insert!(
          Baudrate.Content.Board.changeset(%Baudrate.Content.Board{}, %{
            name: "Was federated",
            slug: "was-federated-#{uid()}"
          })
        )

      activity = %{
        "id" => "#{remote.ap_id}/follows/#{uid()}",
        "type" => "Follow",
        "actor" => remote.ap_id,
        "object" => Federation.actor_uri(:board, board.slug)
      }

      id = stored_id(activity, remote, {:board, board})
      board |> Ecto.Changeset.change(ap_enabled: false) |> Repo.update!()

      assert Inbound.process(id) == :rejected
      assert %InboundActivity{last_error: ":target_gone"} = Repo.get!(InboundActivity, id)
    end

    test "a row that is no longer pending is skipped", %{user: user, remote: remote} do
      id = stored_id(follow(remote, user), remote, :shared)

      assert Inbound.process(id) == :processed
      assert Inbound.process(id) == :skipped
    end

    test "a row whose processing kept taking the node down is given up",
         %{user: user, remote: remote} do
      id = stored_id(follow(remote, user), remote, :shared)
      Repo.update_all(from(a in InboundActivity, where: a.id == ^id), set: [attempts: 3])

      assert Inbound.process(id) == :failed

      assert %InboundActivity{status: "failed", attempts: 4, activity_json: nil} =
               Repo.get!(InboundActivity, id)

      refute Federation.follower_exists?(Federation.actor_uri(:user, user.username), remote.ap_id)
    end
  end

  describe "record_interrupted/2" do
    setup do
      discard_tasks()
      :ok
    end

    test "retries after a backoff, then fails once out of attempts",
         %{user: user, remote: remote} do
      id = stored_id(follow(remote, user), remote, :shared)
      Repo.update_all(from(a in InboundActivity, where: a.id == ^id), set: [attempts: 1])

      assert :ok = Inbound.record_interrupted(id, :timeout)

      row = Repo.get!(InboundActivity, id)
      assert row.status == "pending"
      assert row.last_error == ":timeout"
      assert_in_delta DateTime.diff(row.next_attempt_at, DateTime.utc_now()), 30, 5
      assert row.activity_json

      Repo.update_all(from(a in InboundActivity, where: a.id == ^id), set: [attempts: 3])
      assert :ok = Inbound.record_interrupted(id, {:crashed, :boom})

      assert %InboundActivity{status: "failed", activity_json: nil} =
               Repo.get!(InboundActivity, id)
    end
  end

  describe "purge_finished/0" do
    test "deletes finished rows older than seven days, and nothing pending",
         %{user: user, remote: remote} do
      discard_tasks()
      old = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)

      old_done = stored_id(follow(remote, user), remote, :shared)
      recent_done = stored_id(follow(remote, user), remote, :shared)
      old_pending = stored_id(follow(remote, user), remote, :shared)

      Repo.update_all(from(a in InboundActivity, where: a.id in ^[old_done, recent_done]),
        set: [status: "processed", processed_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      Repo.update_all(from(a in InboundActivity, where: a.id == ^old_done),
        set: [processed_at: old]
      )

      Repo.update_all(from(a in InboundActivity, where: a.id == ^old_pending),
        set: [inserted_at: old]
      )

      assert Inbound.purge_finished() == 1

      assert InboundActivity |> select([a], a.id) |> Repo.all() |> Enum.sort() ==
               Enum.sort([recent_done, old_pending])

      assert Inbound.pending_count() == 1
    end
  end

  # --- Fixtures ---

  defp discard_tasks do
    previous = Application.get_env(:baudrate, :federation_async)
    Application.put_env(:baudrate, :federation_async, :discard)
    on_exit(fn -> Application.put_env(:baudrate, :federation_async, previous) end)
  end

  defp stored_id(activity, remote, target) do
    {:ok, %InboundActivity{id: id}} =
      Inbound.store(activity, Jason.encode!(activity), remote, target)

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

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "inbound_#{uid()}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    user
  end

  defp create_remote_actor(attrs \\ []) do
    id = uid()
    domain = Keyword.get(attrs, :domain, "remote.example")

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://#{domain}/users/inbound-#{id}",
      username: "inbound_#{id}",
      domain: domain,
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://#{domain}/users/inbound-#{id}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp uid, do: System.unique_integer([:positive])
end
