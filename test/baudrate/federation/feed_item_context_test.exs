defmodule Baudrate.Federation.FeedItemContextTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{PubSub, RemoteActor}
  alias Baudrate.Repo

  setup do
    user = setup_user_with_role("user")
    actor = create_remote_actor()
    {:ok, user: user, actor: actor}
  end

  defp setup_user_with_role(role_name) do
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}
    import Ecto.Query

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "feed_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

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

  defp create_accepted_follow(user, actor) do
    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, follow} = Federation.accept_user_follow(follow.ap_id)
    follow
  end

  defp feed_item_attrs(actor, extra \\ %{}) do
    uid = System.unique_integer([:positive])

    Map.merge(
      %{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/#{uid}",
        body: "Hello world",
        body_html: "<p>Hello world</p>",
        source_url: "https://remote.example/notes/#{uid}",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      extra
    )
  end

  describe "create_feed_item/1" do
    test "creates a feed item", %{actor: actor} do
      attrs = feed_item_attrs(actor)
      {:ok, item} = Federation.create_feed_item(attrs)

      assert item.ap_id == attrs.ap_id
      assert item.remote_actor_id == actor.id
      assert item.object_type == "Note"
    end

    test "broadcasts to followers of the actor", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      PubSub.subscribe_user_feed(user.id)

      attrs = feed_item_attrs(actor)
      {:ok, item} = Federation.create_feed_item(attrs)
      expected_id = item.id

      assert_receive {:feed_item_created, %{feed_item_id: ^expected_id}}
    end

    test "does not broadcast when no followers", %{user: user, actor: actor} do
      # No follow created
      PubSub.subscribe_user_feed(user.id)

      attrs = feed_item_attrs(actor)
      {:ok, _item} = Federation.create_feed_item(attrs)

      refute_receive {:feed_item_created, _}
    end

    test "returns error for duplicate ap_id", %{actor: actor} do
      attrs = feed_item_attrs(actor)
      {:ok, _} = Federation.create_feed_item(attrs)
      {:error, changeset} = Federation.create_feed_item(attrs)
      assert errors_on(changeset)[:ap_id]
    end
  end

  describe "list_feed_items/2" do
    test "returns items from followed actors only", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      other_actor = create_remote_actor()

      {:ok, item} = Federation.create_feed_item(feed_item_attrs(actor))
      {:ok, _other} = Federation.create_feed_item(feed_item_attrs(other_actor))

      result = Federation.list_feed_items(user)
      assert length(result.items) == 1
      assert hd(result.items).feed_item.id == item.id
    end

    test "excludes soft-deleted items", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      attrs = feed_item_attrs(actor)
      {:ok, _item} = Federation.create_feed_item(attrs)
      Federation.soft_delete_feed_item_by_ap_id(attrs.ap_id, actor.id)

      result = Federation.list_feed_items(user)
      assert result.items == []
    end

    test "excludes items from pending follows", %{user: user, actor: actor} do
      # Create follow but don't accept it
      {:ok, _follow} = Federation.create_user_follow(user, actor)
      {:ok, _item} = Federation.create_feed_item(feed_item_attrs(actor))

      result = Federation.list_feed_items(user)
      assert result.items == []
    end

    test "filters blocked/muted actors", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      {:ok, _item} = Federation.create_feed_item(feed_item_attrs(actor))

      # Block the actor
      Baudrate.Auth.block_remote_actor(user, actor.ap_id)

      result = Federation.list_feed_items(user)
      assert result.items == []
    end

    test "returns paginated results", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)

      for _ <- 1..25 do
        Federation.create_feed_item(feed_item_attrs(actor))
      end

      result = Federation.list_feed_items(user, page: 1)
      assert length(result.items) == 20
      assert result.total == 25
      assert result.total_pages == 2

      result2 = Federation.list_feed_items(user, page: 2)
      assert length(result2.items) == 5
    end
  end

  describe "get_feed_item_by_ap_id/1" do
    test "returns item when found", %{actor: actor} do
      attrs = feed_item_attrs(actor)
      {:ok, item} = Federation.create_feed_item(attrs)

      found = Federation.get_feed_item_by_ap_id(attrs.ap_id)
      assert found.id == item.id
    end

    test "returns nil when not found" do
      assert Federation.get_feed_item_by_ap_id("https://nonexistent/note/999") == nil
    end
  end

  describe "soft_delete_feed_item_by_ap_id/2" do
    test "soft-deletes matching item", %{actor: actor} do
      attrs = feed_item_attrs(actor)
      {:ok, _item} = Federation.create_feed_item(attrs)

      {1, _} = Federation.soft_delete_feed_item_by_ap_id(attrs.ap_id, actor.id)

      item = Federation.get_feed_item_by_ap_id(attrs.ap_id)
      assert item.deleted_at != nil
    end

    test "does not delete if actor mismatch", %{actor: actor} do
      other_actor = create_remote_actor()
      attrs = feed_item_attrs(actor)
      {:ok, _item} = Federation.create_feed_item(attrs)

      {0, _} = Federation.soft_delete_feed_item_by_ap_id(attrs.ap_id, other_actor.id)

      item = Federation.get_feed_item_by_ap_id(attrs.ap_id)
      assert item.deleted_at == nil
    end
  end

  describe "cleanup_feed_items_for_actor/1" do
    test "soft-deletes all items from actor", %{actor: actor} do
      {:ok, _} = Federation.create_feed_item(feed_item_attrs(actor))
      {:ok, _} = Federation.create_feed_item(feed_item_attrs(actor))

      {2, _} = Federation.cleanup_feed_items_for_actor(actor.id)
    end
  end

  describe "local_followers_of_remote_actor/1" do
    test "returns user IDs with accepted follows", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)

      ids = Federation.local_followers_of_remote_actor(actor.id)
      assert user.id in ids
    end

    test "excludes pending follows", %{user: user, actor: actor} do
      {:ok, _follow} = Federation.create_user_follow(user, actor)

      ids = Federation.local_followers_of_remote_actor(actor.id)
      assert ids == []
    end

    test "returns empty for unfollowed actor", %{actor: actor} do
      assert Federation.local_followers_of_remote_actor(actor.id) == []
    end
  end

  describe "migrate_user_follows/2" do
    test "moves follows to new actor", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor()

      {1, 0} = Federation.migrate_user_follows(actor.id, new_actor.id)

      assert Federation.user_follows?(user.id, new_actor.id)
      refute Federation.user_follows?(user.id, actor.id)
    end

    test "deduplicates when already following new actor", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor()
      create_accepted_follow(user, new_actor)

      {0, 1} = Federation.migrate_user_follows(actor.id, new_actor.id)

      assert Federation.user_follows?(user.id, new_actor.id)
      refute Federation.user_follows?(user.id, actor.id)
    end
  end
end
