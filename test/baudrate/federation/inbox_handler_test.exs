defmodule Baudrate.Federation.InboxHandlerTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Federation
  alias Baudrate.Federation.{InboxHandler, KeyStore, RemoteActor}

  defp setup_user_with_role(role_name) do
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "test_#{System.unique_integer([:positive])}",
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

  defp create_board(slug \\ nil) do
    slug = slug || "board-#{System.unique_integer([:positive])}"

    %Baudrate.Content.Board{}
    |> Baudrate.Content.Board.changeset(%{name: "Test Board", slug: slug})
    |> Repo.insert!()
  end

  defp create_article_for_board(user, board) do
    slug = "art-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Test Article", body: "Body text", slug: slug, user_id: user.id},
        [board.id]
      )

    article
  end

  describe "Follow" do
    test "creates a follower record" do
      user = setup_user_with_role("user")
      {:ok, user} = KeyStore.ensure_user_keypair(user)
      remote_actor = create_remote_actor()

      actor_uri = Federation.actor_uri(:user, user.username)

      activity = %{
        "id" => "https://remote.example/activities/follow-#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => remote_actor.ap_id,
        "object" => actor_uri
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, {:user, user})

      # Give async Accept delivery task time to not interfere
      Process.sleep(50)

      # Verify follower was created
      assert Federation.follower_exists?(actor_uri, remote_actor.ap_id)
    end

    test "idempotent Follow (duplicate) still succeeds" do
      user = setup_user_with_role("user")
      {:ok, user} = KeyStore.ensure_user_keypair(user)
      remote_actor = create_remote_actor()

      actor_uri = Federation.actor_uri(:user, user.username)

      activity = %{
        "id" => "https://remote.example/activities/follow-#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => remote_actor.ap_id,
        "object" => actor_uri
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, {:user, user})
      Process.sleep(50)

      # Second follow with different activity_id
      activity2 =
        Map.put(
          activity,
          "id",
          "https://remote.example/activities/follow-#{System.unique_integer([:positive])}"
        )

      assert :ok = InboxHandler.handle(activity2, remote_actor, {:user, user})
      Process.sleep(50)

      # Still exactly 1 follower
      assert Federation.count_followers(actor_uri) == 1
    end
  end

  describe "Undo(Follow)" do
    test "removes follower record" do
      user = setup_user_with_role("user")
      {:ok, user} = KeyStore.ensure_user_keypair(user)
      remote_actor = create_remote_actor()

      actor_uri = Federation.actor_uri(:user, user.username)

      follow_activity = %{
        "id" => "https://remote.example/activities/follow-#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => remote_actor.ap_id,
        "object" => actor_uri
      }

      assert :ok = InboxHandler.handle(follow_activity, remote_actor, {:user, user})
      Process.sleep(50)
      assert Federation.follower_exists?(actor_uri, remote_actor.ap_id)

      # Now undo the follow
      undo_activity = %{
        "type" => "Undo",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Follow",
          "actor" => remote_actor.ap_id,
          "object" => actor_uri
        }
      }

      assert :ok = InboxHandler.handle(undo_activity, remote_actor, {:user, user})
      refute Federation.follower_exists?(actor_uri, remote_actor.ap_id)
    end
  end

  describe "Create(Note) — remote comment" do
    test "creates a comment on a local article" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "<p>Nice article!</p>",
          "attributedTo" => remote_actor.ap_id,
          "inReplyTo" => article_uri
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      comments = Content.list_comments_for_article(article)
      assert length(comments) == 1
      assert hd(comments).remote_actor_id == remote_actor.id
    end

    test "creates a threaded reply to an existing comment" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)
      comment_ap_id = "https://remote.example/notes/parent-#{System.unique_integer([:positive])}"

      # First comment
      activity1 = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => comment_ap_id,
          "type" => "Note",
          "content" => "First comment",
          "attributedTo" => remote_actor.ap_id,
          "inReplyTo" => article_uri
        }
      }

      assert :ok = InboxHandler.handle(activity1, remote_actor, :shared)

      # Reply to first comment
      activity2 = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/reply-#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "Reply to first comment",
          "attributedTo" => remote_actor.ap_id,
          "inReplyTo" => comment_ap_id
        }
      }

      assert :ok = InboxHandler.handle(activity2, remote_actor, :shared)

      comments = Content.list_comments_for_article(article)
      assert length(comments) == 2

      reply = Enum.find(comments, &(&1.body == "Reply to first comment"))
      parent = Enum.find(comments, &(&1.ap_id == comment_ap_id))
      assert reply.parent_id == parent.id
    end

    test "rejects comment with attribution mismatch" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "Impersonated!",
          "attributedTo" => "https://evil.example/users/impersonator",
          "inReplyTo" => article_uri
        }
      }

      assert {:error, :attribution_mismatch} =
               InboxHandler.handle(activity, remote_actor, :shared)
    end

    test "idempotent — duplicate ap_id returns :ok" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)
      ap_id = "https://remote.example/notes/idem-#{System.unique_integer([:positive])}"

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Note",
          "content" => "Hello",
          "attributedTo" => remote_actor.ap_id,
          "inReplyTo" => article_uri
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      comments = Content.list_comments_for_article(article)
      assert length(comments) == 1
    end

    test "rejects comment with missing inReplyTo" do
      remote_actor = create_remote_actor()

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "No reply target",
          "attributedTo" => remote_actor.ap_id
        }
      }

      assert {:error, :missing_in_reply_to} =
               InboxHandler.handle(activity, remote_actor, :shared)
    end
  end

  describe "Create(Article) — remote article" do
    test "creates a remote article in the target board" do
      _user = setup_user_with_role("user")
      board = create_board()
      remote_actor = create_remote_actor()

      board_uri = Federation.actor_uri(:board, board.slug)

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/articles/#{System.unique_integer([:positive])}",
          "type" => "Article",
          "name" => "Remote Article Title",
          "content" => "<p>Article body from remote</p>",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri],
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      articles = Content.list_articles_for_board(board)
      remote_articles = Enum.filter(articles, &(&1.remote_actor_id == remote_actor.id))
      assert length(remote_articles) == 1
      assert hd(remote_articles).title == "Remote Article Title"
    end

    test "rejects article with no matching board" do
      remote_actor = create_remote_actor()

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/articles/#{System.unique_integer([:positive])}",
          "type" => "Article",
          "name" => "Orphan Article",
          "content" => "No board target",
          "attributedTo" => remote_actor.ap_id,
          "audience" => ["https://remote.example/communities/nonexistent"],
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      assert {:error, :board_not_found} = InboxHandler.handle(activity, remote_actor, :shared)
    end
  end

  describe "Like" do
    test "creates an article like" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)

      activity = %{
        "id" => "https://remote.example/likes/#{System.unique_integer([:positive])}",
        "type" => "Like",
        "actor" => remote_actor.ap_id,
        "object" => article_uri
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
      assert Content.count_article_likes(article) == 1
    end

    test "idempotent — duplicate like returns :ok" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)

      activity = %{
        "id" => "https://remote.example/likes/#{System.unique_integer([:positive])}",
        "type" => "Like",
        "actor" => remote_actor.ap_id,
        "object" => article_uri
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      # Second like with different ap_id but same article/actor
      activity2 = %{
        "id" => "https://remote.example/likes/#{System.unique_integer([:positive])}",
        "type" => "Like",
        "actor" => remote_actor.ap_id,
        "object" => article_uri
      }

      assert :ok = InboxHandler.handle(activity2, remote_actor, :shared)
      assert Content.count_article_likes(article) == 1
    end

    test "ignores like for non-local article" do
      remote_actor = create_remote_actor()

      activity = %{
        "id" => "https://remote.example/likes/#{System.unique_integer([:positive])}",
        "type" => "Like",
        "actor" => remote_actor.ap_id,
        "object" => "https://other.example/articles/something"
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
    end
  end

  describe "Announce" do
    test "creates an announce record" do
      remote_actor = create_remote_actor()
      target_uri = "https://local.example/ap/articles/some-post"

      activity = %{
        "id" => "https://remote.example/activities/announce-#{System.unique_integer([:positive])}",
        "type" => "Announce",
        "actor" => remote_actor.ap_id,
        "object" => target_uri
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
      assert Federation.count_announces(target_uri) == 1
    end

    test "idempotent — duplicate announce returns :ok" do
      remote_actor = create_remote_actor()
      target_uri = "https://local.example/ap/articles/some-post"
      ap_id = "https://remote.example/activities/announce-#{System.unique_integer([:positive])}"

      activity = %{
        "id" => ap_id,
        "type" => "Announce",
        "actor" => remote_actor.ap_id,
        "object" => target_uri
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
      assert Federation.count_announces(target_uri) == 1
    end
  end

  describe "Undo(Like)" do
    test "removes article like" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)
      like_ap_id = "https://remote.example/likes/#{System.unique_integer([:positive])}"

      # Create the like
      like_activity = %{
        "id" => like_ap_id,
        "type" => "Like",
        "actor" => remote_actor.ap_id,
        "object" => article_uri
      }

      assert :ok = InboxHandler.handle(like_activity, remote_actor, :shared)
      assert Content.count_article_likes(article) == 1

      # Undo the like
      undo_activity = %{
        "type" => "Undo",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Like",
          "id" => like_ap_id
        }
      }

      assert :ok = InboxHandler.handle(undo_activity, remote_actor, :shared)
      assert Content.count_article_likes(article) == 0
    end
  end

  describe "Undo(Announce)" do
    test "removes announce record" do
      remote_actor = create_remote_actor()
      target_uri = "https://local.example/ap/articles/some-post"
      announce_ap_id = "https://remote.example/activities/announce-#{System.unique_integer([:positive])}"

      # Create the announce
      announce_activity = %{
        "id" => announce_ap_id,
        "type" => "Announce",
        "actor" => remote_actor.ap_id,
        "object" => target_uri
      }

      assert :ok = InboxHandler.handle(announce_activity, remote_actor, :shared)
      assert Federation.count_announces(target_uri) == 1

      # Undo the announce
      undo_activity = %{
        "type" => "Undo",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Announce",
          "id" => announce_ap_id
        }
      }

      assert :ok = InboxHandler.handle(undo_activity, remote_actor, :shared)
      assert Federation.count_announces(target_uri) == 0
    end
  end

  describe "Delete(content)" do
    test "soft-deletes a remote article" do
      _user = setup_user_with_role("user")
      board = create_board()
      remote_actor = create_remote_actor()
      board_uri = Federation.actor_uri(:board, board.slug)

      ap_id = "https://remote.example/articles/to-delete-#{System.unique_integer([:positive])}"

      # Create remote article first
      create_activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Article",
          "name" => "To Be Deleted",
          "content" => "Will be deleted",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri]
        }
      }

      assert :ok = InboxHandler.handle(create_activity, remote_actor, :shared)
      assert Content.get_article_by_ap_id(ap_id) != nil

      # Delete it
      delete_activity = %{
        "type" => "Delete",
        "actor" => remote_actor.ap_id,
        "object" => ap_id
      }

      assert :ok = InboxHandler.handle(delete_activity, remote_actor, :shared)

      article = Content.get_article_by_ap_id(ap_id)
      assert article.deleted_at != nil
    end

    test "soft-deletes a remote comment" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)
      comment_ap_id = "https://remote.example/notes/to-delete-#{System.unique_integer([:positive])}"

      # Create remote comment first
      create_activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => comment_ap_id,
          "type" => "Note",
          "content" => "To be deleted",
          "attributedTo" => remote_actor.ap_id,
          "inReplyTo" => article_uri
        }
      }

      assert :ok = InboxHandler.handle(create_activity, remote_actor, :shared)

      # Delete it
      delete_activity = %{
        "type" => "Delete",
        "actor" => remote_actor.ap_id,
        "object" => comment_ap_id
      }

      assert :ok = InboxHandler.handle(delete_activity, remote_actor, :shared)

      comment = Content.get_comment_by_ap_id(comment_ap_id)
      assert comment.deleted_at != nil
      assert comment.body == "[deleted]"
    end

    test "rejects delete from non-author" do
      _user = setup_user_with_role("user")
      board = create_board()
      remote_actor = create_remote_actor()
      other_actor = create_remote_actor()
      board_uri = Federation.actor_uri(:board, board.slug)

      ap_id = "https://remote.example/articles/owned-#{System.unique_integer([:positive])}"

      # Create article by remote_actor
      create_activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Article",
          "name" => "Owned by actor",
          "content" => "Body",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri]
        }
      }

      assert :ok = InboxHandler.handle(create_activity, remote_actor, :shared)

      # Try to delete as other_actor
      delete_activity = %{
        "type" => "Delete",
        "actor" => other_actor.ap_id,
        "object" => ap_id
      }

      assert {:error, :unauthorized} =
               InboxHandler.handle(delete_activity, other_actor, :shared)

      # Article still exists and is not deleted
      article = Content.get_article_by_ap_id(ap_id)
      assert is_nil(article.deleted_at)
    end
  end

  describe "Update(content)" do
    test "updates a remote article" do
      _user = setup_user_with_role("user")
      board = create_board()
      remote_actor = create_remote_actor()
      board_uri = Federation.actor_uri(:board, board.slug)

      ap_id = "https://remote.example/articles/to-update-#{System.unique_integer([:positive])}"

      # Create remote article
      create_activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Article",
          "name" => "Original Title",
          "content" => "Original body",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri]
        }
      }

      assert :ok = InboxHandler.handle(create_activity, remote_actor, :shared)

      # Update it
      update_activity = %{
        "type" => "Update",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Article",
          "name" => "Updated Title",
          "content" => "Updated body",
          "attributedTo" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(update_activity, remote_actor, :shared)

      article = Content.get_article_by_ap_id(ap_id)
      assert article.title == "Updated Title"
      assert article.body == "Updated body"
    end

    test "updates a remote comment" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)
      comment_ap_id = "https://remote.example/notes/to-update-#{System.unique_integer([:positive])}"

      # Create remote comment
      create_activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => comment_ap_id,
          "type" => "Note",
          "content" => "Original comment",
          "attributedTo" => remote_actor.ap_id,
          "inReplyTo" => article_uri
        }
      }

      assert :ok = InboxHandler.handle(create_activity, remote_actor, :shared)

      # Update it
      update_activity = %{
        "type" => "Update",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => comment_ap_id,
          "type" => "Note",
          "content" => "Updated comment",
          "attributedTo" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(update_activity, remote_actor, :shared)

      comment = Content.get_comment_by_ap_id(comment_ap_id)
      assert comment.body == "Updated comment"
    end

    test "rejects update from non-author" do
      _user = setup_user_with_role("user")
      board = create_board()
      remote_actor = create_remote_actor()
      other_actor = create_remote_actor()
      board_uri = Federation.actor_uri(:board, board.slug)

      ap_id = "https://remote.example/articles/auth-#{System.unique_integer([:positive])}"

      # Create article by remote_actor
      create_activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Article",
          "name" => "Owned Article",
          "content" => "Body",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri]
        }
      }

      assert :ok = InboxHandler.handle(create_activity, remote_actor, :shared)

      # Try to update as other_actor
      update_activity = %{
        "type" => "Update",
        "actor" => other_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Article",
          "name" => "Hacked Title",
          "content" => "Hacked body",
          "attributedTo" => other_actor.ap_id
        }
      }

      # Attribution mismatch since attributedTo != remote_actor who created it
      # The update handler first checks attribution against the actor sending the activity
      # and then checks ownership via remote_actor_id
      assert {:error, :unauthorized} =
               InboxHandler.handle(update_activity, other_actor, :shared)
    end
  end

  describe "Create(Page) — Lemmy interop" do
    test "creates a remote article from a Page object" do
      _user = setup_user_with_role("user")
      board = create_board()
      remote_actor = create_remote_actor()

      board_uri = Federation.actor_uri(:board, board.slug)

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/post/#{System.unique_integer([:positive])}",
          "type" => "Page",
          "name" => "Lemmy Page Title",
          "content" => "<p>Lemmy page body</p>",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri],
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      articles = Content.list_articles_for_board(board)
      remote_articles = Enum.filter(articles, &(&1.remote_actor_id == remote_actor.id))
      assert length(remote_articles) == 1
      assert hd(remote_articles).title == "Lemmy Page Title"
    end
  end

  describe "Update(Page) — Lemmy interop" do
    test "updates a remote article created from a Page" do
      _user = setup_user_with_role("user")
      board = create_board()
      remote_actor = create_remote_actor()
      board_uri = Federation.actor_uri(:board, board.slug)

      ap_id = "https://remote.example/post/page-update-#{System.unique_integer([:positive])}"

      # Create as Page first
      create_activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Page",
          "name" => "Original Page",
          "content" => "Original content",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri]
        }
      }

      assert :ok = InboxHandler.handle(create_activity, remote_actor, :shared)

      # Update as Page
      update_activity = %{
        "type" => "Update",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Page",
          "name" => "Updated Page Title",
          "content" => "Updated page content",
          "attributedTo" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(update_activity, remote_actor, :shared)

      article = Content.get_article_by_ap_id(ap_id)
      assert article.title == "Updated Page Title"
      assert article.body == "Updated page content"
    end
  end

  describe "Announce with embedded object (Lemmy interop)" do
    test "records announce from embedded object map" do
      remote_actor = create_remote_actor()
      object_id = "https://remote.example/post/#{System.unique_integer([:positive])}"

      activity = %{
        "id" => "https://remote.example/activities/announce-#{System.unique_integer([:positive])}",
        "type" => "Announce",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => object_id,
          "type" => "Page",
          "name" => "Lemmy Post",
          "content" => "Body"
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
      assert Federation.count_announces(object_id) == 1
    end
  end

  describe "attributedTo as array (Mastodon interop)" do
    test "validates correctly when first URI matches" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "Comment with array attribution",
          "attributedTo" => [
            remote_actor.ap_id,
            %{"type" => "Organization", "name" => "Some Org"}
          ],
          "inReplyTo" => article_uri
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      comments = Content.list_comments_for_article(article)
      assert length(comments) == 1
    end

    test "rejects when array URI mismatches" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "Impersonated via array",
          "attributedTo" => [
            "https://evil.example/users/impersonator",
            %{"type" => "Organization"}
          ],
          "inReplyTo" => article_uri
        }
      }

      assert {:error, :attribution_mismatch} =
               InboxHandler.handle(activity, remote_actor, :shared)
    end
  end

  describe "sensitive + summary (content warning)" do
    test "prepends CW to body when sensitive is true" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "<p>Sensitive content here</p>",
          "attributedTo" => remote_actor.ap_id,
          "inReplyTo" => article_uri,
          "sensitive" => true,
          "summary" => "Content Warning"
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      comments = Content.list_comments_for_article(article)
      assert length(comments) == 1

      comment = hd(comments)
      assert comment.body =~ "[CW: Content Warning]"
      assert comment.body =~ "Sensitive content here"
    end

    test "does not prepend CW when sensitive is false" do
      user = setup_user_with_role("user")
      board = create_board()
      article = create_article_for_board(user, board)
      remote_actor = create_remote_actor()

      article_uri = Federation.actor_uri(:article, article.slug)

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "<p>Normal content</p>",
          "attributedTo" => remote_actor.ap_id,
          "inReplyTo" => article_uri,
          "sensitive" => false,
          "summary" => "Not a CW"
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      comments = Content.list_comments_for_article(article)
      comment = hd(comments)
      refute comment.body =~ "[CW:"
    end
  end

  describe "domain blocking" do
    test "rejects activities from blocked domains" do
      Baudrate.Setup.set_setting("ap_domain_blocklist", "blocked-domain.example")

      remote_actor =
        create_remote_actor(%{
          ap_id: "https://blocked-domain.example/users/eve",
          username: "eve",
          domain: "blocked-domain.example",
          inbox: "https://blocked-domain.example/users/eve/inbox"
        })

      activity = %{
        "type" => "Follow",
        "actor" => remote_actor.ap_id,
        "object" => "https://local.example/ap/users/bob"
      }

      assert {:error, :domain_blocked} = InboxHandler.handle(activity, remote_actor, :shared)
    end
  end

  describe "self-referencing actors" do
    test "local_actor? correctly identifies local URIs" do
      base = BaudrateWeb.Endpoint.url()
      assert Baudrate.Federation.Validator.local_actor?("#{base}/ap/users/alice")
      refute Baudrate.Federation.Validator.local_actor?("https://remote.example/users/alice")
    end
  end
end
