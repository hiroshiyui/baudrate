defmodule Baudrate.Federation.UserFollowContextTest do
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
        "username" => "ctx_#{System.unique_integer([:positive])}",
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

  describe "create_user_follow/2" do
    test "creates a pending follow record" do
      user = create_user()
      remote_actor = create_remote_actor()

      assert {:ok, %UserFollow{} = follow} = Federation.create_user_follow(user, remote_actor)
      assert follow.user_id == user.id
      assert follow.remote_actor_id == remote_actor.id
      assert follow.state == "pending"
      assert follow.ap_id =~ "#follow-"
      assert is_nil(follow.accepted_at)
      assert is_nil(follow.rejected_at)
    end

    test "returns error for duplicate follow" do
      user = create_user()
      remote_actor = create_remote_actor()

      assert {:ok, _} = Federation.create_user_follow(user, remote_actor)
      assert {:error, changeset} = Federation.create_user_follow(user, remote_actor)
      assert %{user_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "accept_user_follow/1" do
    test "transitions follow from pending to accepted" do
      user = create_user()
      remote_actor = create_remote_actor()
      {:ok, follow} = Federation.create_user_follow(user, remote_actor)

      assert {:ok, accepted} = Federation.accept_user_follow(follow.ap_id)
      assert accepted.state == "accepted"
      assert accepted.accepted_at != nil
    end

    test "returns error for unknown ap_id" do
      assert {:error, :not_found} =
               Federation.accept_user_follow("https://example.com/nonexistent")
    end
  end

  describe "reject_user_follow/1" do
    test "transitions follow from pending to rejected" do
      user = create_user()
      remote_actor = create_remote_actor()
      {:ok, follow} = Federation.create_user_follow(user, remote_actor)

      assert {:ok, rejected} = Federation.reject_user_follow(follow.ap_id)
      assert rejected.state == "rejected"
      assert rejected.rejected_at != nil
    end

    test "returns error for unknown ap_id" do
      assert {:error, :not_found} =
               Federation.reject_user_follow("https://example.com/nonexistent")
    end
  end

  describe "delete_user_follow/2" do
    test "deletes an existing follow record" do
      user = create_user()
      remote_actor = create_remote_actor()
      {:ok, _} = Federation.create_user_follow(user, remote_actor)

      assert {:ok, _deleted} = Federation.delete_user_follow(user, remote_actor)
      refute Federation.user_follows?(user.id, remote_actor.id)
    end

    test "returns error when no follow exists" do
      user = create_user()
      remote_actor = create_remote_actor()

      assert {:error, :not_found} = Federation.delete_user_follow(user, remote_actor)
    end
  end

  describe "get_user_follow/2" do
    test "returns the follow record" do
      user = create_user()
      remote_actor = create_remote_actor()
      {:ok, created} = Federation.create_user_follow(user, remote_actor)

      follow = Federation.get_user_follow(user.id, remote_actor.id)
      assert follow.id == created.id
    end

    test "returns nil when no follow exists" do
      assert is_nil(Federation.get_user_follow(999_999, 999_999))
    end
  end

  describe "get_user_follow_by_ap_id/1" do
    test "returns the follow record by AP ID" do
      user = create_user()
      remote_actor = create_remote_actor()
      {:ok, created} = Federation.create_user_follow(user, remote_actor)

      follow = Federation.get_user_follow_by_ap_id(created.ap_id)
      assert follow.id == created.id
    end

    test "returns nil for unknown AP ID" do
      assert is_nil(Federation.get_user_follow_by_ap_id("https://nonexistent/follow"))
    end
  end

  describe "user_follows?/2" do
    test "returns true for any state" do
      user = create_user()
      remote_actor = create_remote_actor()
      {:ok, _} = Federation.create_user_follow(user, remote_actor)

      assert Federation.user_follows?(user.id, remote_actor.id)
    end

    test "returns false when no follow exists" do
      refute Federation.user_follows?(999_999, 999_999)
    end
  end

  describe "user_follows_accepted?/2" do
    test "returns true only for accepted follows" do
      user = create_user()
      remote_actor = create_remote_actor()
      {:ok, follow} = Federation.create_user_follow(user, remote_actor)

      refute Federation.user_follows_accepted?(user.id, remote_actor.id)

      Federation.accept_user_follow(follow.ap_id)
      assert Federation.user_follows_accepted?(user.id, remote_actor.id)
    end
  end

  describe "list_user_follows/2" do
    test "lists all follows for a user" do
      user = create_user()
      actor1 = create_remote_actor()
      actor2 = create_remote_actor()

      {:ok, _} = Federation.create_user_follow(user, actor1)
      {:ok, _} = Federation.create_user_follow(user, actor2)

      follows = Federation.list_user_follows(user.id)
      assert length(follows) == 2
      # Preloads remote_actor
      assert Enum.all?(follows, fn f -> f.remote_actor != nil end)
    end

    test "filters by state" do
      user = create_user()
      actor1 = create_remote_actor()
      actor2 = create_remote_actor()

      {:ok, follow1} = Federation.create_user_follow(user, actor1)
      {:ok, _follow2} = Federation.create_user_follow(user, actor2)

      Federation.accept_user_follow(follow1.ap_id)

      accepted = Federation.list_user_follows(user.id, state: "accepted")
      assert length(accepted) == 1
      assert hd(accepted).remote_actor_id == actor1.id

      pending = Federation.list_user_follows(user.id, state: "pending")
      assert length(pending) == 1
      assert hd(pending).remote_actor_id == actor2.id
    end
  end

  describe "count_user_follows/1" do
    test "counts only accepted follows" do
      user = create_user()
      actor1 = create_remote_actor()
      actor2 = create_remote_actor()

      {:ok, follow1} = Federation.create_user_follow(user, actor1)
      {:ok, _follow2} = Federation.create_user_follow(user, actor2)

      assert Federation.count_user_follows(user.id) == 0

      Federation.accept_user_follow(follow1.ap_id)
      assert Federation.count_user_follows(user.id) == 1
    end
  end

  describe "following_collection/2" do
    test "returns paginated collection for user with accepted follows" do
      user = create_user()
      actor1 = create_remote_actor()

      {:ok, follow} = Federation.create_user_follow(user, actor1)
      Federation.accept_user_follow(follow.ap_id)

      actor_uri = Federation.actor_uri(:user, user.username)

      # Root collection
      root = Federation.following_collection(actor_uri)
      assert root["type"] == "OrderedCollection"
      assert root["totalItems"] == 1
      assert root["first"] =~ "?page=1"

      # Page 1
      page = Federation.following_collection(actor_uri, %{"page" => "1"})
      assert page["type"] == "OrderedCollectionPage"
      assert actor1.ap_id in page["orderedItems"]
    end

    test "returns empty collection for board actors" do
      actor_uri = Federation.actor_uri(:board, "test-board")
      collection = Federation.following_collection(actor_uri)

      assert collection["type"] == "OrderedCollection"
      assert collection["totalItems"] == 0
      assert collection["orderedItems"] == []
    end
  end
end
