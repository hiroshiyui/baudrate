defmodule Baudrate.Federation.InboxHandlerFeedTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{InboxHandler, RemoteActor}
  alias Baudrate.Repo

  setup do
    user = setup_user_with_role("user")
    actor = create_remote_actor()
    {:ok, user: user, actor: actor}
  end

  defp setup_user_with_role(role_name) do
    alias Baudrate.Setup
    alias Baudrate.Setup.User
    import Ecto.Query

    unless Repo.exists?(from(r in Baudrate.Setup.Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == ^role_name))

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
    {:ok, _follow} = Federation.accept_user_follow(follow.ap_id)
  end

  defp note_activity(actor, extra \\ %{}) do
    uid = System.unique_integer([:positive])

    object =
      Map.merge(
        %{
          "type" => "Note",
          "id" => "https://remote.example/notes/#{uid}",
          "content" => "<p>Hello from remote</p>",
          "attributedTo" => actor.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "published" => DateTime.to_iso8601(DateTime.utc_now())
        },
        extra
      )

    %{
      "type" => "Create",
      "id" => "https://remote.example/activities/#{uid}",
      "actor" => actor.ap_id,
      "object" => object
    }
  end

  defp article_activity(actor, extra \\ %{}) do
    uid = System.unique_integer([:positive])

    object =
      Map.merge(
        %{
          "type" => "Article",
          "id" => "https://remote.example/articles/#{uid}",
          "name" => "Test Article #{uid}",
          "content" => "<p>Article content</p>",
          "attributedTo" => actor.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "published" => DateTime.to_iso8601(DateTime.utc_now())
        },
        extra
      )

    %{
      "type" => "Create",
      "id" => "https://remote.example/activities/article-#{uid}",
      "actor" => actor.ap_id,
      "object" => object
    }
  end

  describe "Create(Note) feed item fallback" do
    test "creates feed item from followed actor without inReplyTo", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      activity = note_activity(actor)
      ap_id = activity["object"]["id"]

      assert :ok = InboxHandler.handle(activity, actor, :shared)
      assert Federation.get_feed_item_by_ap_id(ap_id) != nil
    end

    test "silently drops note from unfollowed actor", %{actor: actor} do
      activity = note_activity(actor)
      ap_id = activity["object"]["id"]

      assert :ok = InboxHandler.handle(activity, actor, :shared)
      assert Federation.get_feed_item_by_ap_id(ap_id) == nil
    end

    test "note replying to local article becomes comment, not feed item", %{
      user: user,
      actor: actor
    } do
      create_accepted_follow(user, actor)

      # Create a local article
      board = create_board()

      {:ok, multi} =
        Baudrate.Content.create_article(
          %{
            title: "Local Article",
            body: "Content",
            slug: "local-article-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      article = multi.article

      article_ap_id = Federation.actor_uri(:article, article.slug)

      activity =
        note_activity(actor, %{
          "inReplyTo" => article_ap_id
        })

      assert :ok = InboxHandler.handle(activity, actor, :shared)

      # Should be a comment, not a feed item
      assert Federation.get_feed_item_by_ap_id(activity["object"]["id"]) == nil
      assert Baudrate.Content.get_comment_by_ap_id(activity["object"]["id"]) != nil
    end

    test "DM note becomes DM, not feed item", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      user_uri = Federation.actor_uri(:user, user.username)

      activity =
        note_activity(actor, %{
          "to" => [user_uri],
          "cc" => []
        })

      assert :ok = InboxHandler.handle(activity, actor, :shared)
      assert Federation.get_feed_item_by_ap_id(activity["object"]["id"]) == nil
    end
  end

  describe "Create(Article) feed item fallback" do
    test "creates feed item when no board audience from followed actor", %{
      user: user,
      actor: actor
    } do
      create_accepted_follow(user, actor)
      activity = article_activity(actor)
      ap_id = activity["object"]["id"]

      assert :ok = InboxHandler.handle(activity, actor, :shared)
      assert item = Federation.get_feed_item_by_ap_id(ap_id)
      assert item.object_type == "Article"
      assert item.title =~ "Test Article"
    end

    test "article addressed to local board goes to board, not feed", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      board = create_board(%{ap_enabled: true, min_role_to_view: "guest"})
      board_uri = Federation.actor_uri(:board, board.slug)

      activity =
        article_activity(actor, %{
          "audience" => [board_uri],
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [board_uri]
        })

      assert :ok = InboxHandler.handle(activity, actor, :shared)

      # Should be a board article, not a feed item
      assert Federation.get_feed_item_by_ap_id(activity["object"]["id"]) == nil
      assert Baudrate.Content.get_article_by_ap_id(activity["object"]["id"]) != nil
    end
  end

  describe "Delete for feed items" do
    test "soft-deletes feed item by ap_id", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      activity = note_activity(actor)
      ap_id = activity["object"]["id"]

      :ok = InboxHandler.handle(activity, actor, :shared)
      assert Federation.get_feed_item_by_ap_id(ap_id) != nil

      delete_activity = %{
        "type" => "Delete",
        "id" => "https://remote.example/activities/delete-#{System.unique_integer([:positive])}",
        "actor" => actor.ap_id,
        "object" => ap_id
      }

      assert :ok = InboxHandler.handle(delete_activity, actor, :shared)

      item = Federation.get_feed_item_by_ap_id(ap_id)
      assert item.deleted_at != nil
    end
  end

  describe "Delete(actor) cleans up feed items" do
    test "soft-deletes all feed items from actor", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)

      activity1 = note_activity(actor)
      activity2 = note_activity(actor)

      :ok = InboxHandler.handle(activity1, actor, :shared)
      :ok = InboxHandler.handle(activity2, actor, :shared)

      delete_activity = %{
        "type" => "Delete",
        "id" =>
          "https://remote.example/activities/delete-actor-#{System.unique_integer([:positive])}",
        "actor" => actor.ap_id,
        "object" => actor.ap_id
      }

      assert :ok = InboxHandler.handle(delete_activity, actor, :shared)

      item1 = Federation.get_feed_item_by_ap_id(activity1["object"]["id"])
      item2 = Federation.get_feed_item_by_ap_id(activity2["object"]["id"])
      assert item1.deleted_at != nil
      assert item2.deleted_at != nil
    end
  end

  defp create_board(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      name: "Board #{uid}",
      slug: "board-#{uid}",
      description: "Test board",
      position: uid,
      min_role_to_view: "guest",
      min_role_to_post: "user",
      ap_enabled: false,
      ap_accept_policy: "open"
    }

    {:ok, board} =
      %Baudrate.Content.Board{}
      |> Baudrate.Content.Board.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    board
  end
end
