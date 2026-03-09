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

  describe "Announce feed item" do
    test "creates feed item when followed actor boosts content", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      Baudrate.Federation.KeyStore.ensure_site_keypair()

      content_author = create_remote_actor(%{display_name: "Content Author"})
      uid = System.unique_integer([:positive])
      object_uri = "https://remote.example/notes/boosted-#{uid}"
      announce_ap_id = "https://remote.example/activities/announce-#{uid}"

      # Stub HTTP client to return the boosted object
      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "type" => "Note",
          "id" => object_uri,
          "content" => "<p>Boosted content</p>",
          "attributedTo" => content_author.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "published" => DateTime.to_iso8601(DateTime.utc_now()),
          "url" => "https://remote.example/@author/#{uid}"
        }))
      end)

      announce_activity = %{
        "id" => announce_ap_id,
        "type" => "Announce",
        "actor" => actor.ap_id,
        "object" => object_uri
      }

      assert :ok = InboxHandler.handle(announce_activity, actor, :shared)

      # Should create both announce record and feed item
      assert Federation.count_announces(object_uri) == 1
      item = Federation.get_feed_item_by_ap_id(announce_ap_id)
      assert item != nil
      assert item.activity_type == "Announce"
      assert item.boosted_by_actor_id == actor.id
      assert item.remote_actor_id == content_author.id
      assert item.source_url == "https://remote.example/@author/#{uid}"
    end

    test "extracts image attachments from boosted content", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)

      content_author = create_remote_actor()
      uid = System.unique_integer([:positive])
      object_id = "https://remote.example/notes/with-images-#{uid}"
      announce_ap_id = "https://remote.example/activities/announce-img-#{uid}"

      announce_activity = %{
        "id" => announce_ap_id,
        "type" => "Announce",
        "actor" => actor.ap_id,
        "object" => %{
          "type" => "Note",
          "id" => object_id,
          "content" => "<p>Check out these photos</p>",
          "attributedTo" => content_author.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "published" => DateTime.to_iso8601(DateTime.utc_now()),
          "attachment" => [
            %{
              "type" => "Document",
              "mediaType" => "image/jpeg",
              "url" => "https://remote.example/media/photo1.jpg",
              "name" => "A nice photo"
            },
            %{
              "type" => "Document",
              "mediaType" => "image/png",
              "url" => "https://remote.example/media/photo2.png",
              "name" => ""
            }
          ]
        }
      }

      assert :ok = InboxHandler.handle(announce_activity, actor, :shared)

      item = Federation.get_feed_item_by_ap_id(announce_ap_id)
      assert item != nil
      assert length(item.attachments) == 2
      assert Enum.at(item.attachments, 0)["url"] == "https://remote.example/media/photo1.jpg"
      assert Enum.at(item.attachments, 0)["name"] == "A nice photo"
      assert Enum.at(item.attachments, 1)["url"] == "https://remote.example/media/photo2.png"
    end

    test "extracts image attachments from Create feed items", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)

      activity = note_activity(actor, %{
        "attachment" => [
          %{
            "type" => "Document",
            "mediaType" => "image/webp",
            "url" => "https://remote.example/media/img.webp",
            "name" => "WebP image"
          },
          %{
            "type" => "Document",
            "mediaType" => "video/mp4",
            "url" => "https://remote.example/media/video.mp4",
            "name" => "A video"
          }
        ]
      })

      assert :ok = InboxHandler.handle(activity, actor, :shared)

      item = Federation.get_feed_item_by_ap_id(activity["object"]["id"])
      assert item != nil
      # Only images, not video
      assert length(item.attachments) == 1
      assert Enum.at(item.attachments, 0)["url"] == "https://remote.example/media/img.webp"
    end

    test "does not create feed item when booster is not followed", %{actor: actor} do
      announce_ap_id = "https://remote.example/activities/announce-#{System.unique_integer([:positive])}"
      object_uri = "https://remote.example/notes/some-post"

      announce_activity = %{
        "id" => announce_ap_id,
        "type" => "Announce",
        "actor" => actor.ap_id,
        "object" => object_uri
      }

      assert :ok = InboxHandler.handle(announce_activity, actor, :shared)

      # Announce record created but no feed item (no followers)
      assert Federation.count_announces(object_uri) == 1
      assert Federation.get_feed_item_by_ap_id(announce_ap_id) == nil
    end

    test "creates feed item from embedded Announce object (Lemmy interop)", %{
      user: user,
      actor: actor
    } do
      create_accepted_follow(user, actor)

      content_author = create_remote_actor()
      uid = System.unique_integer([:positive])
      object_id = "https://remote.example/notes/embedded-#{uid}"
      announce_ap_id = "https://remote.example/activities/announce-embedded-#{uid}"

      announce_activity = %{
        "id" => announce_ap_id,
        "type" => "Announce",
        "actor" => actor.ap_id,
        "object" => %{
          "type" => "Note",
          "id" => object_id,
          "content" => "<p>Embedded boosted content</p>",
          "attributedTo" => content_author.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "published" => DateTime.to_iso8601(DateTime.utc_now())
        }
      }

      assert :ok = InboxHandler.handle(announce_activity, actor, :shared)

      # Should create a feed item with Announce type
      item = Federation.get_feed_item_by_ap_id(announce_ap_id)
      assert item != nil
      assert item.activity_type == "Announce"
      assert item.boosted_by_actor_id == actor.id
      assert item.remote_actor_id == content_author.id
    end

    test "Announce feed item appears in user's feed", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)

      content_author = create_remote_actor()
      uid = System.unique_integer([:positive])
      announce_ap_id = "https://remote.example/activities/announce-feed-#{uid}"

      # Directly create an Announce feed item
      {:ok, _feed_item} =
        Federation.create_feed_item(%{
          remote_actor_id: content_author.id,
          boosted_by_actor_id: actor.id,
          activity_type: "Announce",
          object_type: "Note",
          ap_id: announce_ap_id,
          title: nil,
          body: "Boosted content",
          body_html: "<p>Boosted content</p>",
          source_url: "https://remote.example/notes/#{uid}",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      result = Federation.list_feed_items(user)
      assert Enum.any?(result.items, fn item ->
        item.source == :remote and item.feed_item.ap_id == announce_ap_id
      end)

      # Verify boost attribution is preloaded
      boost_item =
        Enum.find(result.items, fn item ->
          item.source == :remote and item.feed_item.ap_id == announce_ap_id
        end)

      assert boost_item.feed_item.boosted_by_actor != nil
      assert boost_item.feed_item.boosted_by_actor.id == actor.id
    end
  end

  describe "Announce board routing" do
    test "routes boosted Article to boards following the booster", %{actor: actor} do
      board = create_board(%{ap_enabled: true, min_role_to_view: "guest"})

      # Board follows the booster actor
      {:ok, follow} = Federation.create_board_follow(board, actor)
      {:ok, _} = Federation.accept_board_follow(follow.ap_id)

      content_author = create_remote_actor()
      uid = System.unique_integer([:positive])
      object_id = "https://remote.example/articles/boosted-#{uid}"
      announce_ap_id = "https://remote.example/activities/announce-board-#{uid}"

      announce_activity = %{
        "id" => announce_ap_id,
        "type" => "Announce",
        "actor" => actor.ap_id,
        "object" => %{
          "type" => "Article",
          "id" => object_id,
          "name" => "Boosted Article #{uid}",
          "content" => "<p>Boosted article content</p>",
          "attributedTo" => content_author.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "published" => DateTime.to_iso8601(DateTime.utc_now()),
          "url" => "https://remote.example/@author/articles/#{uid}"
        }
      }

      assert :ok = InboxHandler.handle(announce_activity, actor, :shared)

      # Article should be created and linked to the board
      article = Baudrate.Content.get_article_by_ap_id(object_id)
      assert article != nil
      assert article.remote_actor_id == content_author.id
      assert article.url == "https://remote.example/@author/articles/#{uid}"

      # Article should be in the board
      board_articles = Baudrate.Content.list_articles_for_board(board)
      assert Enum.any?(board_articles, &(&1.id == article.id))
    end

    test "does not route boosted Note to boards (Notes are feed-only)", %{actor: actor} do
      board = create_board(%{ap_enabled: true, min_role_to_view: "guest"})

      {:ok, follow} = Federation.create_board_follow(board, actor)
      {:ok, _} = Federation.accept_board_follow(follow.ap_id)

      content_author = create_remote_actor()
      uid = System.unique_integer([:positive])
      object_id = "https://remote.example/notes/boosted-note-#{uid}"
      announce_ap_id = "https://remote.example/activities/announce-note-#{uid}"

      announce_activity = %{
        "id" => announce_ap_id,
        "type" => "Announce",
        "actor" => actor.ap_id,
        "object" => %{
          "type" => "Note",
          "id" => object_id,
          "content" => "<p>Boosted note</p>",
          "attributedTo" => content_author.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "published" => DateTime.to_iso8601(DateTime.utc_now())
        }
      }

      assert :ok = InboxHandler.handle(announce_activity, actor, :shared)

      # Note should NOT become a board article
      assert Baudrate.Content.get_article_by_ap_id(object_id) == nil
    end

    test "deduplicates — does not create duplicate article from repeated boost", %{actor: actor} do
      board = create_board(%{ap_enabled: true, min_role_to_view: "guest"})

      {:ok, follow} = Federation.create_board_follow(board, actor)
      {:ok, _} = Federation.accept_board_follow(follow.ap_id)

      # Create a second booster also followed by the board
      booster2 = create_remote_actor()
      {:ok, follow2} = Federation.create_board_follow(board, booster2)
      {:ok, _} = Federation.accept_board_follow(follow2.ap_id)

      content_author = create_remote_actor()
      uid = System.unique_integer([:positive])
      object_id = "https://remote.example/articles/dedup-#{uid}"

      embedded_article = %{
        "type" => "Article",
        "id" => object_id,
        "name" => "Dedup Article",
        "content" => "<p>Content</p>",
        "attributedTo" => content_author.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "published" => DateTime.to_iso8601(DateTime.utc_now())
      }

      # First boost
      announce1 = %{
        "id" => "https://remote.example/activities/announce-dedup1-#{uid}",
        "type" => "Announce",
        "actor" => actor.ap_id,
        "object" => embedded_article
      }

      assert :ok = InboxHandler.handle(announce1, actor, :shared)
      article = Baudrate.Content.get_article_by_ap_id(object_id)
      assert article != nil

      # Second boost of the same article by different actor
      announce2 = %{
        "id" => "https://remote.example/activities/announce-dedup2-#{uid}",
        "type" => "Announce",
        "actor" => booster2.ap_id,
        "object" => embedded_article
      }

      assert :ok = InboxHandler.handle(announce2, booster2, :shared)

      # Should still be the same single article (not duplicated)
      import Ecto.Query
      count = Repo.aggregate(from(a in Baudrate.Content.Article, where: a.ap_id == ^object_id), :count)
      assert count == 1
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
