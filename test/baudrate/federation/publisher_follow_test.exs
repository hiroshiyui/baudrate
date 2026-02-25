defmodule Baudrate.Federation.PublisherFollowTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{KeyStore, Publisher, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "pfol_#{System.unique_integer([:positive])}",
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
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
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

  describe "build_follow/3" do
    test "builds a Follow activity" do
      user = create_user()
      remote_actor = create_remote_actor()
      follow_ap_id = "#{Federation.actor_uri(:user, user.username)}#follow-123"

      {activity, actor_uri} = Publisher.build_follow(user, remote_actor, follow_ap_id)

      assert activity["type"] == "Follow"
      assert activity["actor"] == actor_uri
      assert activity["object"] == remote_actor.ap_id
      assert activity["id"] == follow_ap_id
      assert activity["@context"] == "https://www.w3.org/ns/activitystreams"
      assert actor_uri =~ user.username
    end
  end

  describe "build_undo_follow/2" do
    test "builds an Undo(Follow) activity" do
      user = create_user()
      remote_actor = create_remote_actor()
      {:ok, follow} = Federation.create_user_follow(user, remote_actor)
      follow = Repo.preload(follow, :remote_actor)

      {activity, actor_uri} = Publisher.build_undo_follow(user, follow)

      assert activity["type"] == "Undo"
      assert activity["actor"] == actor_uri
      assert activity["id"] =~ "#undo-follow-"
      assert activity["@context"] == "https://www.w3.org/ns/activitystreams"

      inner = activity["object"]
      assert inner["type"] == "Follow"
      assert inner["id"] == follow.ap_id
      assert inner["actor"] == actor_uri
      assert inner["object"] == remote_actor.ap_id
    end
  end
end
