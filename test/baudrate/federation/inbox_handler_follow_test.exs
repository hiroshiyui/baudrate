defmodule Baudrate.Federation.InboxHandlerFollowTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{InboxHandler, KeyStore, RemoteActor}

  defp create_user do
    import Ecto.Query

    unless Repo.exists?(from(r in Baudrate.Setup.Role, where: r.name == "admin")) do
      Baudrate.Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "ihf_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    Repo.preload(user, :role)
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/actor-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    actor
  end

  describe "Accept(Follow) with object map" do
    test "marks outbound follow as accepted" do
      user = create_user()
      remote_actor = create_remote_actor()

      {:ok, follow} = Federation.create_user_follow(user, remote_actor)
      assert follow.state == "pending"

      actor_uri = Federation.actor_uri(:user, user.username)

      activity = %{
        "id" => "#{remote_actor.ap_id}#accept-follow-1",
        "type" => "Accept",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Follow",
          "id" => follow.ap_id,
          "actor" => actor_uri,
          "object" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      updated = Federation.get_user_follow_by_ap_id(follow.ap_id)
      assert updated.state == "accepted"
      assert updated.accepted_at != nil
    end

    test "returns :ok when follow not found" do
      remote_actor = create_remote_actor()

      activity = %{
        "id" => "#{remote_actor.ap_id}#accept-follow-notfound",
        "type" => "Accept",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Follow",
          "id" => "https://local.example/nonexistent-follow",
          "actor" => "https://local.example/ap/users/unknown",
          "object" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
    end

    test "returns :ok when follow object has no id" do
      remote_actor = create_remote_actor()

      activity = %{
        "id" => "#{remote_actor.ap_id}#accept-follow-noid",
        "type" => "Accept",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Follow",
          "actor" => "https://local.example/ap/users/unknown",
          "object" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
    end
  end

  describe "Accept(Follow) with string URI object" do
    test "marks outbound follow as accepted when object is a string" do
      user = create_user()
      remote_actor = create_remote_actor()

      {:ok, follow} = Federation.create_user_follow(user, remote_actor)

      activity = %{
        "id" => "#{remote_actor.ap_id}#accept-follow-str",
        "type" => "Accept",
        "actor" => remote_actor.ap_id,
        "object" => follow.ap_id
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      updated = Federation.get_user_follow_by_ap_id(follow.ap_id)
      assert updated.state == "accepted"
    end
  end

  describe "Reject(Follow) with object map" do
    test "marks outbound follow as rejected" do
      user = create_user()
      remote_actor = create_remote_actor()

      {:ok, follow} = Federation.create_user_follow(user, remote_actor)
      assert follow.state == "pending"

      actor_uri = Federation.actor_uri(:user, user.username)

      activity = %{
        "id" => "#{remote_actor.ap_id}#reject-follow-1",
        "type" => "Reject",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Follow",
          "id" => follow.ap_id,
          "actor" => actor_uri,
          "object" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      updated = Federation.get_user_follow_by_ap_id(follow.ap_id)
      assert updated.state == "rejected"
      assert updated.rejected_at != nil
    end

    test "returns :ok when follow not found" do
      remote_actor = create_remote_actor()

      activity = %{
        "id" => "#{remote_actor.ap_id}#reject-follow-notfound",
        "type" => "Reject",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Follow",
          "id" => "https://local.example/nonexistent-follow",
          "actor" => "https://local.example/ap/users/unknown",
          "object" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
    end
  end

  describe "Reject(Follow) with string URI object" do
    test "marks outbound follow as rejected when object is a string" do
      user = create_user()
      remote_actor = create_remote_actor()

      {:ok, follow} = Federation.create_user_follow(user, remote_actor)

      activity = %{
        "id" => "#{remote_actor.ap_id}#reject-follow-str",
        "type" => "Reject",
        "actor" => remote_actor.ap_id,
        "object" => follow.ap_id
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      updated = Federation.get_user_follow_by_ap_id(follow.ap_id)
      assert updated.state == "rejected"
    end
  end
end
