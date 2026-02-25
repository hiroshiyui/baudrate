defmodule Baudrate.Federation.LocalFollowTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{KeyStore, RemoteActor, UserFollow}

  defp create_user do
    import Ecto.Query

    unless Repo.exists?(from(r in Baudrate.Setup.Role, where: r.name == "admin")) do
      Baudrate.Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "user_#{System.unique_integer([:positive])}",
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
      display_name: "Remote Actor #{uid}",
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

  setup do
    follower = create_user()
    followed = create_user()
    {:ok, follower: follower, followed: followed}
  end

  describe "create_local_follow/2" do
    test "creates an accepted follow immediately", %{follower: follower, followed: followed} do
      assert {:ok, %UserFollow{} = follow} =
               Federation.create_local_follow(follower, followed)

      assert follow.user_id == follower.id
      assert follow.followed_user_id == followed.id
      assert follow.state == "accepted"
      assert follow.accepted_at != nil
      assert follow.remote_actor_id == nil
      assert follow.ap_id != nil
    end

    test "prevents self-follow", %{follower: follower} do
      assert {:error, :self_follow} = Federation.create_local_follow(follower, follower)
    end

    test "prevents duplicate follows", %{follower: follower, followed: followed} do
      assert {:ok, _follow} = Federation.create_local_follow(follower, followed)
      assert {:error, %Ecto.Changeset{}} = Federation.create_local_follow(follower, followed)
    end
  end

  describe "delete_local_follow/2" do
    test "removes follow", %{follower: follower, followed: followed} do
      {:ok, _follow} = Federation.create_local_follow(follower, followed)
      assert {:ok, _follow} = Federation.delete_local_follow(follower, followed)
      refute Federation.local_follows?(follower.id, followed.id)
    end

    test "returns error when no follow exists", %{follower: follower, followed: followed} do
      assert {:error, :not_found} = Federation.delete_local_follow(follower, followed)
    end
  end

  describe "local_follows?/2" do
    test "returns true when follow exists", %{follower: follower, followed: followed} do
      {:ok, _} = Federation.create_local_follow(follower, followed)
      assert Federation.local_follows?(follower.id, followed.id)
    end

    test "returns false when no follow exists", %{follower: follower, followed: followed} do
      refute Federation.local_follows?(follower.id, followed.id)
    end
  end

  describe "get_local_follow/2" do
    test "returns follow when it exists", %{follower: follower, followed: followed} do
      {:ok, _} = Federation.create_local_follow(follower, followed)
      follow = Federation.get_local_follow(follower.id, followed.id)
      assert follow != nil
      assert follow.followed_user_id == followed.id
    end

    test "returns nil when no follow exists", %{follower: follower, followed: followed} do
      assert Federation.get_local_follow(follower.id, followed.id) == nil
    end
  end

  describe "list_user_follows/1" do
    test "returns both local and remote follows", %{follower: follower, followed: followed} do
      # Create a local follow
      {:ok, _} = Federation.create_local_follow(follower, followed)

      # Create a remote follow
      remote_actor = create_remote_actor()
      {:ok, _} = Federation.create_user_follow(follower, remote_actor)

      follows = Federation.list_user_follows(follower.id)
      assert length(follows) == 2

      local_follow = Enum.find(follows, &(&1.followed_user_id != nil))
      remote_follow = Enum.find(follows, &(&1.remote_actor_id != nil))

      assert local_follow.followed_user != nil
      assert remote_follow.remote_actor != nil
    end
  end

  describe "count_user_follows/1" do
    test "counts accepted local follows", %{follower: follower, followed: followed} do
      {:ok, _} = Federation.create_local_follow(follower, followed)
      assert Federation.count_user_follows(follower.id) == 1
    end
  end

  describe "local_followers_of_user/1" do
    test "returns follower user IDs", %{follower: follower, followed: followed} do
      {:ok, _} = Federation.create_local_follow(follower, followed)
      follower_ids = Federation.local_followers_of_user(followed.id)
      assert follower.id in follower_ids
    end
  end

  describe "following_collection/2" do
    test "includes local follow URIs", %{follower: follower, followed: followed} do
      {:ok, _} = Federation.create_local_follow(follower, followed)

      actor_uri = Federation.actor_uri(:user, follower.username)
      result = Federation.following_collection(actor_uri, %{"page" => "1"})

      assert result["type"] == "OrderedCollectionPage"
      expected_uri = Federation.actor_uri(:user, followed.username)
      assert expected_uri in result["orderedItems"]
    end

    test "includes both local and remote follow URIs", %{follower: follower, followed: followed} do
      {:ok, _} = Federation.create_local_follow(follower, followed)
      remote_actor = create_remote_actor()
      {:ok, follow} = Federation.create_user_follow(follower, remote_actor)
      Federation.accept_user_follow(follow.ap_id)

      actor_uri = Federation.actor_uri(:user, follower.username)
      result = Federation.following_collection(actor_uri, %{"page" => "1"})

      items = result["orderedItems"]
      assert length(items) == 2
      assert Federation.actor_uri(:user, followed.username) in items
      assert remote_actor.ap_id in items
    end
  end
end
