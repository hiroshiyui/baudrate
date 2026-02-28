defmodule Baudrate.ContentTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{Article, Board}
  alias Baudrate.Setup
  alias Baudrate.Federation.{KeyStore, RemoteActor}

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name) do
    role = Repo.one!(from r in Setup.Role, where: r.name == ^role_name)

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board(attrs) do
    %Board{}
    |> Board.changeset(attrs)
    |> Repo.insert!()
  end

  # --- Boards ---

  describe "list_top_boards/0" do
    test "returns only top-level boards" do
      parent = create_board(%{name: "Parent", slug: "parent"})
      create_board(%{name: "Child", slug: "child", parent_id: parent.id})

      boards = Content.list_top_boards()
      slugs = Enum.map(boards, & &1.slug)

      assert "parent" in slugs
      refute "child" in slugs
    end

    test "returns boards ordered by position" do
      create_board(%{name: "B", slug: "board-b", position: 2})
      create_board(%{name: "A", slug: "board-a", position: 1})

      boards = Content.list_top_boards()
      assert [%{slug: "board-a"}, %{slug: "board-b"}] = boards
    end

    test "returns empty list when no boards exist" do
      assert Content.list_top_boards() == []
    end
  end

  describe "list_sub_boards/1" do
    test "returns child boards of the given parent" do
      parent = create_board(%{name: "Parent", slug: "parent2"})
      create_board(%{name: "Sub1", slug: "sub1", parent_id: parent.id, position: 1})
      create_board(%{name: "Sub2", slug: "sub2", parent_id: parent.id, position: 2})

      subs = Content.list_sub_boards(parent)
      slugs = Enum.map(subs, & &1.slug)

      assert slugs == ["sub1", "sub2"]
    end

    test "returns empty list when board has no children" do
      parent = create_board(%{name: "Lonely", slug: "lonely"})
      assert Content.list_sub_boards(parent) == []
    end
  end

  describe "get_board_by_slug!/1" do
    test "returns board by slug" do
      create_board(%{name: "Test", slug: "test-board"})
      board = Content.get_board_by_slug!("test-board")
      assert board.name == "Test"
    end

    test "raises when slug not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Content.get_board_by_slug!("nonexistent")
      end
    end
  end

  # --- Article Permission Functions ---

  describe "article permission functions" do
    setup do
      admin = create_user("admin")
      author = create_user("user")
      mod = create_user("moderator")
      other = create_user("user")
      board = create_board(%{name: "Perm Board", slug: "perm-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Perm Test", body: "body", slug: "perm-test", user_id: author.id},
          [board.id]
        )

      {:ok, _} = Content.add_board_moderator(board.id, mod.id)

      %{admin: admin, author: author, mod: mod, other: other, article: article, board: board}
    end

    test "can_edit_article? — admin can edit", %{admin: admin, article: article} do
      assert Content.can_edit_article?(admin, article)
    end

    test "can_edit_article? — author can edit", %{author: author, article: article} do
      assert Content.can_edit_article?(author, article)
    end

    test "can_edit_article? — board mod cannot edit", %{mod: mod, article: article} do
      refute Content.can_edit_article?(mod, article)
    end

    test "can_edit_article? — other user cannot edit", %{other: other, article: article} do
      refute Content.can_edit_article?(other, article)
    end

    test "can_delete_article? — admin can delete", %{admin: admin, article: article} do
      assert Content.can_delete_article?(admin, article)
    end

    test "can_delete_article? — author can delete", %{author: author, article: article} do
      assert Content.can_delete_article?(author, article)
    end

    test "can_delete_article? — board mod can delete", %{mod: mod, article: article} do
      assert Content.can_delete_article?(mod, article)
    end

    test "can_delete_article? — other user cannot delete", %{other: other, article: article} do
      refute Content.can_delete_article?(other, article)
    end

    test "can_pin_article? — admin can pin", %{admin: admin, article: article} do
      assert Content.can_pin_article?(admin, article)
    end

    test "can_pin_article? — board mod can pin", %{mod: mod, article: article} do
      assert Content.can_pin_article?(mod, article)
    end

    test "can_pin_article? — author cannot pin", %{author: author, article: article} do
      refute Content.can_pin_article?(author, article)
    end

    test "can_pin_article? — other user cannot pin", %{other: other, article: article} do
      refute Content.can_pin_article?(other, article)
    end

    test "can_lock_article? — admin can lock", %{admin: admin, article: article} do
      assert Content.can_lock_article?(admin, article)
    end

    test "can_lock_article? — board mod can lock", %{mod: mod, article: article} do
      assert Content.can_lock_article?(mod, article)
    end

    test "can_lock_article? — author cannot lock", %{author: author, article: article} do
      refute Content.can_lock_article?(author, article)
    end

    test "can_lock_article? — other user cannot lock", %{other: other, article: article} do
      refute Content.can_lock_article?(other, article)
    end

    test "permissions unchanged on soft-deleted article", %{
      admin: admin,
      author: author,
      mod: mod,
      other: other,
      article: article
    } do
      {:ok, deleted} = Content.soft_delete_article(article)

      assert Content.can_edit_article?(admin, deleted)
      assert Content.can_edit_article?(author, deleted)
      refute Content.can_edit_article?(mod, deleted)
      refute Content.can_edit_article?(other, deleted)

      assert Content.can_delete_article?(admin, deleted)
      assert Content.can_delete_article?(mod, deleted)
      refute Content.can_delete_article?(other, deleted)
    end

    test "permissions unchanged on locked article", %{
      admin: admin,
      author: author,
      mod: mod,
      other: other,
      article: article
    } do
      {:ok, locked} = Content.toggle_lock_article(article)

      assert Content.can_edit_article?(admin, locked)
      assert Content.can_edit_article?(author, locked)
      refute Content.can_edit_article?(mod, locked)
      refute Content.can_edit_article?(other, locked)

      assert Content.can_pin_article?(admin, locked)
      assert Content.can_pin_article?(mod, locked)
      refute Content.can_pin_article?(author, locked)
    end
  end

  # --- Articles ---

  describe "create_article/2" do
    test "creates article and links to boards" do
      user = create_user("user")
      board = create_board(%{name: "Board", slug: "article-board"})

      attrs = %{
        title: "Hello World",
        body: "This is a test article.",
        slug: "hello-world",
        user_id: user.id
      }

      assert {:ok, %{article: article, board_articles: 1}} =
               Content.create_article(attrs, [board.id])

      assert article.title == "Hello World"
      assert article.slug == "hello-world"
    end

    test "creates article linked to multiple boards" do
      user = create_user("user")
      b1 = create_board(%{name: "B1", slug: "b1"})
      b2 = create_board(%{name: "B2", slug: "b2"})

      attrs = %{
        title: "Cross Post",
        body: "Posted in two boards.",
        slug: "cross-post",
        user_id: user.id
      }

      assert {:ok, %{article: _article, board_articles: 2}} =
               Content.create_article(attrs, [b1.id, b2.id])
    end

    test "rejects article with missing title" do
      user = create_user("user")
      board = create_board(%{name: "Board", slug: "val-board"})

      attrs = %{body: "No title", slug: "no-title", user_id: user.id}

      assert {:error, :article, changeset, _} = Content.create_article(attrs, [board.id])
      assert %{title: _} = errors_on(changeset)
    end

    test "ignores pinned and locked params (mass assignment protection)" do
      user = create_user("user")
      board = create_board(%{name: "Board", slug: "mass-assign-board"})

      attrs = %{
        title: "Sneaky",
        body: "Trying to set pinned/locked",
        slug: "sneaky-article",
        user_id: user.id,
        pinned: true,
        locked: true
      }

      assert {:ok, %{article: article}} = Content.create_article(attrs, [board.id])
      assert article.pinned == false
      assert article.locked == false
    end

    test "rejects duplicate slug" do
      user = create_user("user")
      board = create_board(%{name: "Board", slug: "dup-board"})

      attrs = %{
        title: "First",
        body: "First article",
        slug: "dup-slug",
        user_id: user.id
      }

      assert {:ok, _} = Content.create_article(attrs, [board.id])
      assert {:error, :article, _changeset, _} = Content.create_article(attrs, [board.id])
    end

    test "forwardable defaults to true" do
      user = create_user("user")
      board = create_board(%{name: "Board", slug: "fwd-default-board"})

      attrs = %{
        title: "Default Forwardable",
        body: "body",
        slug: "fwd-default-#{System.unique_integer([:positive])}",
        user_id: user.id
      }

      assert {:ok, %{article: article}} = Content.create_article(attrs, [board.id])
      assert article.forwardable == true
    end

    test "forwardable can be set to false" do
      user = create_user("user")
      board = create_board(%{name: "Board", slug: "fwd-false-board"})

      attrs = %{
        title: "Not Forwardable",
        body: "body",
        slug: "fwd-false-#{System.unique_integer([:positive])}",
        user_id: user.id,
        forwardable: false
      }

      assert {:ok, %{article: article}} = Content.create_article(attrs, [board.id])
      assert article.forwardable == false
    end
  end

  describe "list_articles_for_board/1" do
    test "returns articles in a board, pinned first" do
      user = create_user("user")
      board = create_board(%{name: "Board", slug: "list-board"})

      {:ok, %{article: _normal}} =
        Content.create_article(
          %{title: "Normal", body: "b", slug: "normal", user_id: user.id},
          [board.id]
        )

      {:ok, %{article: pinned}} =
        Content.create_article(
          %{title: "Pinned", body: "b", slug: "pinned", user_id: user.id},
          [board.id]
        )

      Content.toggle_pin_article(pinned)

      articles = Content.list_articles_for_board(board)
      titles = Enum.map(articles, & &1.title)
      assert hd(titles) == "Pinned"
    end

    test "returns empty list for board with no articles" do
      board = create_board(%{name: "Empty", slug: "empty-board"})
      assert Content.list_articles_for_board(board) == []
    end
  end

  describe "get_article_by_slug!/1" do
    test "returns article with boards and user preloaded" do
      user = create_user("user")
      board = create_board(%{name: "Board", slug: "slug-board"})

      {:ok, %{article: _}} =
        Content.create_article(
          %{title: "Find Me", body: "body", slug: "find-me", user_id: user.id},
          [board.id]
        )

      article = Content.get_article_by_slug!("find-me")
      assert article.title == "Find Me"
      assert Ecto.assoc_loaded?(article.boards)
      assert Ecto.assoc_loaded?(article.user)
      assert hd(article.boards).slug == "slug-board"
    end

    test "raises when article slug not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Content.get_article_by_slug!("nonexistent")
      end
    end
  end

  describe "change_article/2" do
    test "returns a changeset" do
      changeset = Content.change_article(%Article{}, %{title: "Test"})
      assert %Ecto.Changeset{} = changeset
    end
  end

  describe "generate_slug/1" do
    test "generates slug from title" do
      slug = Content.generate_slug("Hello World")
      assert String.starts_with?(slug, "hello-world-")
      assert Regex.match?(~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, slug)
    end

    test "handles special characters" do
      slug = Content.generate_slug("What's New? (2026)")
      assert Regex.match?(~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, slug)
    end

    test "handles empty title" do
      slug = Content.generate_slug("")
      # Should still produce a valid slug (just the random suffix)
      assert Regex.match?(~r/\A[a-z0-9]+\z/, slug)
    end

    test "produces unique slugs for same title" do
      slug1 = Content.generate_slug("Same Title")
      slug2 = Content.generate_slug("Same Title")
      assert slug1 != slug2
    end
  end

  # --- Cross-post ---

  describe "add_article_to_board/2" do
    test "links article to a new board" do
      user = create_user("user")
      board1 = create_board(%{name: "Board 1", slug: "xp-board-1"})
      board2 = create_board(%{name: "Board 2", slug: "xp-board-2"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Cross-post", body: "body", slug: "xpost", user_id: user.id},
          [board1.id]
        )

      assert {:ok, _} = Content.add_article_to_board(article, board2.id)

      articles = Content.list_articles_for_board(board2)
      assert length(articles) == 1
      assert hd(articles).id == article.id
    end

    test "is idempotent for same board" do
      user = create_user("user")
      board = create_board(%{name: "Idem Board", slug: "idem-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Idem Post", body: "body", slug: "idem-post", user_id: user.id},
          [board.id]
        )

      assert {:ok, _} = Content.add_article_to_board(article, board.id)

      articles = Content.list_articles_for_board(board)
      assert length(articles) == 1
    end
  end

  # --- Remote Articles ---

  defp create_remote_actor do
    uid = System.unique_integer([:positive])
    {public_pem, _} = KeyStore.generate_keypair()

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/actor-#{uid}",
        username: "actor_#{uid}",
        domain: "remote.example",
        public_key_pem: public_pem,
        inbox: "https://remote.example/users/actor-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    actor
  end

  describe "create_remote_article/2" do
    test "creates a remote article linked to a board" do
      board = create_board(%{name: "Remote Board", slug: "remote-board"})
      remote_actor = create_remote_actor()

      attrs = %{
        title: "Remote Post",
        body: "Body from remote",
        slug: "remote-post-#{System.unique_integer([:positive])}",
        ap_id: "https://remote.example/articles/#{System.unique_integer([:positive])}",
        remote_actor_id: remote_actor.id
      }

      assert {:ok, %{article: article}} = Content.create_remote_article(attrs, [board.id])
      assert article.remote_actor_id == remote_actor.id
      assert article.ap_id != nil
    end
  end

  describe "get_article_by_ap_id/1" do
    test "returns article by ap_id" do
      board = create_board(%{name: "AP Board", slug: "ap-board"})
      remote_actor = create_remote_actor()
      ap_id = "https://remote.example/articles/#{System.unique_integer([:positive])}"

      {:ok, %{article: _}} =
        Content.create_remote_article(
          %{
            title: "AP Article",
            body: "Body",
            slug: "ap-art-#{System.unique_integer([:positive])}",
            ap_id: ap_id,
            remote_actor_id: remote_actor.id
          },
          [board.id]
        )

      assert %Article{} = Content.get_article_by_ap_id(ap_id)
    end

    test "returns nil for unknown ap_id" do
      assert Content.get_article_by_ap_id("https://unknown.example/articles/999") == nil
    end
  end

  describe "create_article delivery hooks" do
    test "enqueues delivery jobs after article creation" do
      user = create_user("user")
      {:ok, user} = Baudrate.Federation.KeyStore.ensure_user_keypair(user)
      board = create_board(%{name: "Hook Board", slug: "hook-board"})
      {:ok, board} = Baudrate.Federation.KeyStore.ensure_board_keypair(board)

      # Create a follower for the user
      uid = System.unique_integer([:positive])
      {public_pem, _} = KeyStore.generate_keypair()

      {:ok, remote_actor} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/hook-#{uid}",
          username: "hook_#{uid}",
          domain: "remote.example",
          public_key_pem: public_pem,
          inbox: "https://remote.example/users/hook-#{uid}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      user_uri = Baudrate.Federation.actor_uri(:user, user.username)

      Baudrate.Federation.create_follower(
        user_uri,
        remote_actor,
        "https://remote.example/activities/follow-#{uid}"
      )

      # Set shared mode so async tasks can access the DB
      Ecto.Adapters.SQL.Sandbox.mode(Baudrate.Repo, {:shared, self()})

      # Create article — should trigger delivery
      {:ok, %{article: _article}} =
        Content.create_article(
          %{title: "Hooked", body: "body", slug: "hooked-#{uid}", user_id: user.id},
          [board.id]
        )

      # Wait for async task
      Process.sleep(300)

      # Check that delivery jobs were created
      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) >= 1

      inbox_urls = Enum.map(jobs, & &1.inbox_url)
      assert remote_actor.inbox in inbox_urls
    end
  end

  describe "soft_delete_article/1" do
    test "sets deleted_at on article" do
      user = create_user("user")
      board = create_board(%{name: "Del Board", slug: "del-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "To Delete", body: "body", slug: "to-delete", user_id: user.id},
          [board.id]
        )

      assert {:ok, deleted} = Content.soft_delete_article(article)
      assert deleted.deleted_at != nil
    end

    test "double soft-delete is idempotent" do
      user = create_user("user")
      board = create_board(%{name: "Idem Del Board", slug: "idem-del-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Double Delete", body: "body", slug: "double-del", user_id: user.id},
          [board.id]
        )

      assert {:ok, first_del} = Content.soft_delete_article(article)
      assert first_del.deleted_at != nil

      assert {:ok, second_del} = Content.soft_delete_article(first_del)
      assert second_del.deleted_at != nil
    end

    test "soft-deleted articles excluded from list_articles_for_board" do
      user = create_user("user")
      board = create_board(%{name: "SD Board", slug: "sd-board"})

      {:ok, %{article: _article}} =
        Content.create_article(
          %{title: "Visible", body: "body", slug: "visible", user_id: user.id},
          [board.id]
        )

      {:ok, %{article: to_delete}} =
        Content.create_article(
          %{title: "Hidden", body: "body", slug: "hidden", user_id: user.id},
          [board.id]
        )

      Content.soft_delete_article(to_delete)

      articles = Content.list_articles_for_board(board)
      titles = Enum.map(articles, & &1.title)
      assert "Visible" in titles
      refute "Hidden" in titles
    end
  end

  # --- Comments ---

  describe "create_remote_comment/1" do
    test "creates a remote comment" do
      user = create_user("user")
      board = create_board(%{name: "Cmt Board", slug: "cmt-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Article", body: "body", slug: "cmt-art", user_id: user.id},
          [board.id]
        )

      remote_actor = create_remote_actor()

      assert {:ok, comment} =
               Content.create_remote_comment(%{
                 body: "Nice post!",
                 body_html: "<p>Nice post!</p>",
                 ap_id: "https://remote.example/notes/#{System.unique_integer([:positive])}",
                 article_id: article.id,
                 remote_actor_id: remote_actor.id
               })

      assert comment.remote_actor_id == remote_actor.id
    end
  end

  describe "list_comments_for_article/1" do
    test "excludes soft-deleted comments" do
      user = create_user("user")
      board = create_board(%{name: "List Cmt Board", slug: "list-cmt-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Article", body: "body", slug: "list-cmt-art", user_id: user.id},
          [board.id]
        )

      remote_actor = create_remote_actor()

      {:ok, c1} =
        Content.create_remote_comment(%{
          body: "Visible comment",
          ap_id: "https://remote.example/notes/visible-#{System.unique_integer([:positive])}",
          article_id: article.id,
          remote_actor_id: remote_actor.id
        })

      {:ok, c2} =
        Content.create_remote_comment(%{
          body: "Deleted comment",
          ap_id: "https://remote.example/notes/deleted-#{System.unique_integer([:positive])}",
          article_id: article.id,
          remote_actor_id: remote_actor.id
        })

      Content.soft_delete_comment(c2)

      comments = Content.list_comments_for_article(article)
      assert length(comments) == 1
      assert hd(comments).id == c1.id
    end
  end

  describe "soft_delete_comment/1 idempotency" do
    test "double soft-delete is idempotent" do
      user = create_user("user")
      board = create_board(%{name: "Idem Cmt Board", slug: "idem-cmt-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Idem Cmt Art", body: "body", slug: "idem-cmt-art", user_id: user.id},
          [board.id]
        )

      remote_actor = create_remote_actor()

      {:ok, comment} =
        Content.create_remote_comment(%{
          body: "Will be double deleted",
          ap_id: "https://remote.example/notes/idem-#{System.unique_integer([:positive])}",
          article_id: article.id,
          remote_actor_id: remote_actor.id
        })

      assert {:ok, first_del} = Content.soft_delete_comment(comment)
      assert first_del.deleted_at != nil
      assert first_del.body == "[deleted]"

      assert {:ok, second_del} = Content.soft_delete_comment(first_del)
      assert second_del.deleted_at != nil
      assert second_del.body == "[deleted]"
    end
  end

  # --- last_activity_at ---

  describe "last_activity_at" do
    setup do
      user = create_user("user")
      board = create_board(%{name: "Activity Board", slug: "activity-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Activity Art", body: "body", slug: "activity-art", user_id: user.id},
          [board.id]
        )

      article = Repo.get!(Article, article.id)
      %{user: user, board: board, article: article}
    end

    test "is set on article creation", %{article: article} do
      assert article.last_activity_at != nil
    end

    test "is updated when a local comment is created", %{article: article, user: user} do
      # Push article's last_activity_at back to ensure a visible difference
      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

      from(a in Article, where: a.id == ^article.id)
      |> Repo.update_all(set: [last_activity_at: past])

      {:ok, _comment} =
        Content.create_comment(%{
          "body" => "A comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      updated_article = Repo.get!(Article, article.id)
      assert DateTime.compare(updated_article.last_activity_at, past) == :gt
    end

    test "is updated when a remote comment is created", %{article: article} do
      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

      from(a in Article, where: a.id == ^article.id)
      |> Repo.update_all(set: [last_activity_at: past])

      remote_actor = create_remote_actor()

      {:ok, _comment} =
        Content.create_remote_comment(%{
          body: "Remote comment",
          ap_id: "https://remote.example/notes/act-#{System.unique_integer([:positive])}",
          article_id: article.id,
          remote_actor_id: remote_actor.id
        })

      updated_article = Repo.get!(Article, article.id)
      assert DateTime.compare(updated_article.last_activity_at, past) == :gt
    end

    test "is recalculated when a comment is soft-deleted", %{article: article, user: user} do
      # Push article's inserted_at and last_activity_at back
      past = DateTime.add(DateTime.utc_now(), -120, :second) |> DateTime.truncate(:second)

      from(a in Article, where: a.id == ^article.id)
      |> Repo.update_all(set: [last_activity_at: past, inserted_at: past])

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "To be deleted",
          "article_id" => article.id,
          "user_id" => user.id
        })

      after_comment = Repo.get!(Article, article.id)
      assert DateTime.compare(after_comment.last_activity_at, past) == :gt

      {:ok, _} = Content.soft_delete_comment(comment)

      after_delete = Repo.get!(Article, article.id)
      # Should fall back to article.inserted_at since no comments remain
      assert DateTime.compare(after_delete.last_activity_at, past) in [:eq, :lt]

      assert DateTime.compare(after_delete.last_activity_at, after_comment.last_activity_at) ==
               :lt
    end
  end

  # --- Article Likes ---

  describe "create_remote_article_like/1" do
    test "creates a remote like" do
      user = create_user("user")
      board = create_board(%{name: "Like Board", slug: "like-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Likeable", body: "body", slug: "likeable", user_id: user.id},
          [board.id]
        )

      remote_actor = create_remote_actor()

      assert {:ok, like} =
               Content.create_remote_article_like(%{
                 ap_id: "https://remote.example/likes/#{System.unique_integer([:positive])}",
                 article_id: article.id,
                 remote_actor_id: remote_actor.id
               })

      assert like.article_id == article.id
    end
  end

  describe "count_article_likes/1" do
    test "counts likes for an article" do
      user = create_user("user")
      board = create_board(%{name: "Count Board", slug: "count-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Popular", body: "body", slug: "popular", user_id: user.id},
          [board.id]
        )

      assert Content.count_article_likes(article) == 0

      actor1 = create_remote_actor()
      actor2 = create_remote_actor()

      Content.create_remote_article_like(%{
        ap_id: "https://remote.example/likes/#{System.unique_integer([:positive])}",
        article_id: article.id,
        remote_actor_id: actor1.id
      })

      Content.create_remote_article_like(%{
        ap_id: "https://remote.example/likes/#{System.unique_integer([:positive])}",
        article_id: article.id,
        remote_actor_id: actor2.id
      })

      assert Content.count_article_likes(article) == 2
    end
  end

  describe "delete_article_like_by_ap_id/1" do
    test "deletes a like by ap_id" do
      user = create_user("user")
      board = create_board(%{name: "Undo Board", slug: "undo-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Undoable", body: "body", slug: "undoable", user_id: user.id},
          [board.id]
        )

      remote_actor = create_remote_actor()
      ap_id = "https://remote.example/likes/#{System.unique_integer([:positive])}"

      Content.create_remote_article_like(%{
        ap_id: ap_id,
        article_id: article.id,
        remote_actor_id: remote_actor.id
      })

      assert Content.count_article_likes(article) == 1
      Content.delete_article_like_by_ap_id(ap_id)
      assert Content.count_article_likes(article) == 0
    end
  end

  # --- Search ---

  describe "search_articles/2" do
    test "English query returns matching articles" do
      user = create_user("user")

      board =
        create_board(%{name: "Search Board", slug: "search-board", min_role_to_view: "guest"})

      {:ok, %{article: _}} =
        Content.create_article(
          %{
            title: "Elixir Tutorial",
            body: "Learn Elixir programming",
            slug: "elixir-tut",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, %{article: _}} =
        Content.create_article(
          %{
            title: "Phoenix Guide",
            body: "Building web apps",
            slug: "phoenix-guide",
            user_id: user.id
          },
          [board.id]
        )

      result = Content.search_articles("Elixir", user: user)
      assert result.total >= 1
      assert Enum.any?(result.articles, &(&1.title == "Elixir Tutorial"))
    end

    test "CJK query returns matching articles" do
      user = create_user("user")
      board = create_board(%{name: "CJK Board", slug: "cjk-board", min_role_to_view: "guest"})

      {:ok, %{article: _}} =
        Content.create_article(
          %{title: "Elixir入門ガイド", body: "Elixirの基本", slug: "elixir-cjk", user_id: user.id},
          [board.id]
        )

      result = Content.search_articles("入門", user: user)
      assert result.total >= 1
      assert Enum.any?(result.articles, &(&1.title == "Elixir入門ガイド"))
    end

    test "respects board visibility for guests" do
      user = create_user("user")

      public_board =
        create_board(%{name: "Public", slug: "pub-search", min_role_to_view: "guest"})

      private_board =
        create_board(%{name: "Private", slug: "priv-search", min_role_to_view: "user"})

      {:ok, %{article: _}} =
        Content.create_article(
          %{title: "Public Article", body: "visible content", slug: "pub-art", user_id: user.id},
          [public_board.id]
        )

      {:ok, %{article: _}} =
        Content.create_article(
          %{title: "Private Article", body: "hidden content", slug: "priv-art", user_id: user.id},
          [private_board.id]
        )

      # Guest search — should only see public board articles
      result = Content.search_articles("Article", user: nil)
      titles = Enum.map(result.articles, & &1.title)
      assert "Public Article" in titles
      refute "Private Article" in titles
    end

    test "returns empty for non-matching query" do
      user = create_user("user")

      board =
        create_board(%{name: "Empty Search", slug: "empty-search", min_role_to_view: "guest"})

      {:ok, _} =
        Content.create_article(
          %{title: "Some Title", body: "Some body", slug: "some-art", user_id: user.id},
          [board.id]
        )

      result = Content.search_articles("zzzznonexistent", user: user)
      assert result.total == 0
      assert result.articles == []
    end

    test "pagination works" do
      user = create_user("user")

      board =
        create_board(%{name: "Paginated", slug: "paginated-search", min_role_to_view: "guest"})

      for i <- 1..5 do
        {:ok, _} =
          Content.create_article(
            %{
              title: "Batch Article #{i}",
              body: "batch content",
              slug: "batch-#{i}",
              user_id: user.id
            },
            [board.id]
          )
      end

      result = Content.search_articles("batch", user: user, per_page: 2, page: 1)
      assert length(result.articles) == 2
      assert result.total == 5
      assert result.total_pages == 3

      result2 = Content.search_articles("batch", user: user, per_page: 2, page: 3)
      assert length(result2.articles) == 1
    end
  end

  describe "search_comments/2" do
    test "English query matches comment body" do
      user = create_user("user")
      board = create_board(%{name: "Cmt Search", slug: "cmt-search", min_role_to_view: "guest"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Article With Comments",
            body: "body",
            slug: "cmt-search-art",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, _} =
        Content.create_comment(%{
          "body" => "This is a great discussion about testing",
          "article_id" => article.id,
          "user_id" => user.id
        })

      result = Content.search_comments("discussion", user: user)
      assert result.total >= 1
      assert Enum.any?(result.comments, &String.contains?(&1.body, "discussion"))
    end

    test "CJK query matches comment body" do
      user = create_user("user")
      board = create_board(%{name: "CJK Cmt", slug: "cjk-cmt", min_role_to_view: "guest"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "CJK Article", body: "body", slug: "cjk-cmt-art", user_id: user.id},
          [board.id]
        )

      {:ok, _} =
        Content.create_comment(%{
          "body" => "これは素晴らしい記事です",
          "article_id" => article.id,
          "user_id" => user.id
        })

      result = Content.search_comments("素晴らしい", user: user)
      assert result.total >= 1
      assert Enum.any?(result.comments, &String.contains?(&1.body, "素晴らしい"))
    end

    test "respects board visibility" do
      user = create_user("user")

      public_board =
        create_board(%{name: "Pub Cmt", slug: "pub-cmt-search", min_role_to_view: "guest"})

      private_board =
        create_board(%{name: "Priv Cmt", slug: "priv-cmt-search", min_role_to_view: "user"})

      {:ok, %{article: pub_article}} =
        Content.create_article(
          %{title: "Pub Art", body: "body", slug: "pub-cmt-art", user_id: user.id},
          [public_board.id]
        )

      {:ok, %{article: priv_article}} =
        Content.create_article(
          %{title: "Priv Art", body: "body", slug: "priv-cmt-art", user_id: user.id},
          [private_board.id]
        )

      {:ok, _} =
        Content.create_comment(%{
          "body" => "Public board comment searchable",
          "article_id" => pub_article.id,
          "user_id" => user.id
        })

      {:ok, _} =
        Content.create_comment(%{
          "body" => "Private board comment searchable",
          "article_id" => priv_article.id,
          "user_id" => user.id
        })

      # Guest search — should only see comments in public boards
      result = Content.search_comments("searchable", user: nil)
      assert result.total == 1
      assert hd(result.comments).body =~ "Public"
    end

    test "excludes soft-deleted comments" do
      user = create_user("user")

      board =
        create_board(%{name: "Del Cmt Search", slug: "del-cmt-search", min_role_to_view: "guest"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Art Del Cmt", body: "body", slug: "del-cmt-art", user_id: user.id},
          [board.id]
        )

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "This comment will be deleted searchterm",
          "article_id" => article.id,
          "user_id" => user.id
        })

      Content.soft_delete_comment(comment)

      result = Content.search_comments("searchterm", user: user)
      assert result.total == 0
    end

    test "returns empty for non-matching query" do
      result = Content.search_comments("zzzznonexistent", user: nil)
      assert result.total == 0
      assert result.comments == []
    end
  end

  # --- PubSub Broadcasts ---

  describe "PubSub broadcasts" do
    alias Baudrate.Content.PubSub, as: ContentPubSub

    test "create_article/2 broadcasts :article_created to board topic" do
      user = create_user("user")
      board = create_board(%{name: "PubSub Board", slug: "pubsub-board"})
      ContentPubSub.subscribe_board(board.id)

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "PubSub Article", body: "body", slug: "pubsub-art", user_id: user.id},
          [board.id]
        )

      article_id = article.id
      assert_receive {:article_created, %{article_id: ^article_id}}
    end

    test "soft_delete_article/1 broadcasts :article_deleted to board and article topics" do
      user = create_user("user")
      board = create_board(%{name: "Del PubSub", slug: "del-pubsub"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "To Delete", body: "body", slug: "del-pubsub-art", user_id: user.id},
          [board.id]
        )

      article_id = article.id
      ContentPubSub.subscribe_board(board.id)
      ContentPubSub.subscribe_article(article.id)

      {:ok, _} = Content.soft_delete_article(article)

      assert_receive {:article_deleted, %{article_id: ^article_id}}
      assert_receive {:article_deleted, %{article_id: ^article_id}}
    end

    test "create_comment/1 broadcasts :comment_created to article topic" do
      user = create_user("user")
      board = create_board(%{name: "Cmt PubSub", slug: "cmt-pubsub"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Comment Article", body: "body", slug: "cmt-pubsub-art", user_id: user.id},
          [board.id]
        )

      ContentPubSub.subscribe_article(article.id)

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "Hello!",
          "article_id" => article.id,
          "user_id" => user.id
        })

      comment_id = comment.id
      assert_receive {:comment_created, %{comment_id: ^comment_id}}
    end

    test "create_remote_comment/1 broadcasts :comment_created to article topic" do
      user = create_user("user")
      board = create_board(%{name: "Remote Cmt PS", slug: "remote-cmt-ps"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Remote Cmt Art", body: "body", slug: "remote-cmt-ps-art", user_id: user.id},
          [board.id]
        )

      remote_actor = create_remote_actor()
      ContentPubSub.subscribe_article(article.id)

      {:ok, comment} =
        Content.create_remote_comment(%{
          body: "Remote comment!",
          body_html: "<p>Remote comment!</p>",
          ap_id: "https://remote.example/notes/ps-#{System.unique_integer([:positive])}",
          article_id: article.id,
          remote_actor_id: remote_actor.id
        })

      comment_id = comment.id
      assert_receive {:comment_created, %{comment_id: ^comment_id}}
    end

    test "soft_delete_comment/1 broadcasts :comment_deleted to article topic" do
      user = create_user("user")
      board = create_board(%{name: "Del Cmt PS", slug: "del-cmt-ps"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Del Cmt Art", body: "body", slug: "del-cmt-ps-art", user_id: user.id},
          [board.id]
        )

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "To delete",
          "article_id" => article.id,
          "user_id" => user.id
        })

      comment_id = comment.id
      ContentPubSub.subscribe_article(article.id)

      {:ok, _} = Content.soft_delete_comment(comment)

      assert_receive {:comment_deleted, %{comment_id: ^comment_id}}
    end

    test "toggle_pin_article/1 broadcasts :article_pinned/:article_unpinned to board topic" do
      user = create_user("user")
      board = create_board(%{name: "Pin PubSub", slug: "pin-pubsub"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Pin Article", body: "body", slug: "pin-pubsub-art", user_id: user.id},
          [board.id]
        )

      article_id = article.id
      ContentPubSub.subscribe_board(board.id)

      {:ok, _} = Content.toggle_pin_article(article)
      assert_receive {:article_pinned, %{article_id: ^article_id}}

      # Toggle again — should be unpinned
      pinned_article = %{article | pinned: true}
      {:ok, _} = Content.toggle_pin_article(pinned_article)
      assert_receive {:article_unpinned, %{article_id: ^article_id}}
    end

    test "toggle_lock_article/1 broadcasts :article_locked/:article_unlocked to board topic" do
      user = create_user("user")
      board = create_board(%{name: "Lock PubSub", slug: "lock-pubsub"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Lock Article", body: "body", slug: "lock-pubsub-art", user_id: user.id},
          [board.id]
        )

      article_id = article.id
      ContentPubSub.subscribe_board(board.id)

      {:ok, _} = Content.toggle_lock_article(article)
      assert_receive {:article_locked, %{article_id: ^article_id}}

      # Toggle again — should be unlocked
      locked_article = %{article | locked: true}
      {:ok, _} = Content.toggle_lock_article(locked_article)
      assert_receive {:article_unlocked, %{article_id: ^article_id}}
    end
  end

  # --- SysOp Board ---

  describe "delete_board/1 SysOp protection" do
    test "returns {:error, :protected} for SysOp board" do
      user = create_user("admin")
      {:ok, sysop_board} = Content.seed_sysop_board(user)
      assert {:error, :protected} = Content.delete_board(sysop_board)
    end
  end

  describe "seed_sysop_board/1" do
    test "creates sysop board and assigns moderator" do
      user = create_user("admin")
      assert {:ok, board} = Content.seed_sysop_board(user)
      assert board.slug == "sysop"
      assert board.name == "SysOp"
    end

    test "fails on duplicate slug" do
      user = create_user("admin")
      assert {:ok, _} = Content.seed_sysop_board(user)
      assert {:error, _} = Content.seed_sysop_board(user)
    end
  end

  # --- Search Boards ---

  describe "search_boards/2" do
    test "returns matching boards" do
      user = create_user("user")
      create_board(%{name: "Elixir Discussion", slug: "elixir-disc"})
      create_board(%{name: "Rust Talk", slug: "rust-talk"})

      results = Content.search_boards("Elix", user)
      assert length(results) == 1
      assert hd(results).slug == "elixir-disc"
    end

    test "respects role permissions" do
      user = create_user("user")
      create_board(%{name: "Admin Only", slug: "admin-only", min_role_to_post: "admin"})
      create_board(%{name: "Open Board", slug: "open-board"})

      results = Content.search_boards("Board", user)
      slugs = Enum.map(results, & &1.slug)
      assert "open-board" in slugs
      refute "admin-only" in slugs
    end

    test "returns empty list when no match" do
      user = create_user("user")
      create_board(%{name: "General", slug: "general-search"})

      assert Content.search_boards("Nonexistent", user) == []
    end
  end

  # --- Forward Article to Board ---

  describe "forward_article_to_board/3" do
    setup do
      author = create_user("user")
      admin = create_user("admin")
      other = create_user("user")
      board = create_board(%{name: "Target Board", slug: "target-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Boardless Article",
            body: "body",
            slug: "boardless-fwd-#{System.unique_integer([:positive])}",
            user_id: author.id
          },
          []
        )

      %{author: author, admin: admin, other: other, board: board, article: article}
    end

    test "forwards board-less article to board", %{
      author: author,
      board: board,
      article: article
    } do
      assert {:ok, updated} = Content.forward_article_to_board(article, board, author)
      assert length(updated.boards) == 1
      assert hd(updated.boards).id == board.id
    end

    test "admin can forward another user's article", %{
      admin: admin,
      board: board,
      article: article
    } do
      assert {:ok, updated} = Content.forward_article_to_board(article, board, admin)
      assert length(updated.boards) == 1
    end

    test "silently succeeds when article already in target board", %{
      author: author,
      board: board
    } do
      {:ok, %{article: posted}} =
        Content.create_article(
          %{
            title: "Posted",
            body: "body",
            slug: "posted-fwd-#{System.unique_integer([:positive])}",
            user_id: author.id
          },
          [board.id]
        )

      assert {:ok, returned} = Content.forward_article_to_board(posted, board, author)
      assert returned.id == posted.id
    end

    test "any user can forward forwardable article with boards to another board", %{
      author: author,
      board: board,
      other: other
    } do
      {:ok, %{article: posted}} =
        Content.create_article(
          %{
            title: "Forwardable",
            body: "body",
            slug: "fwdable-#{System.unique_integer([:positive])}",
            user_id: author.id,
            forwardable: true
          },
          [board.id]
        )

      board2 =
        create_board(%{name: "Board 2", slug: "board2-fwd-#{System.unique_integer([:positive])}"})

      assert {:ok, updated} = Content.forward_article_to_board(posted, board2, other)
      assert length(updated.boards) == 2
    end

    test "returns error when article is not forwardable", %{author: author, board: board} do
      {:ok, %{article: posted}} =
        Content.create_article(
          %{
            title: "Not Forwardable",
            body: "body",
            slug: "nofwd-#{System.unique_integer([:positive])}",
            user_id: author.id,
            forwardable: false
          },
          [board.id]
        )

      board2 =
        create_board(%{name: "Board NF", slug: "board-nf-#{System.unique_integer([:positive])}"})

      other = create_user("user")
      assert {:error, :not_forwardable} = Content.forward_article_to_board(posted, board2, other)
    end

    test "returns error when user is not authorized", %{
      other: other,
      board: board,
      article: article
    } do
      assert {:error, :unauthorized} =
               Content.forward_article_to_board(article, board, other)
    end

    test "returns error when user cannot post in board", %{author: author, article: article} do
      restricted =
        create_board(%{name: "Admin Only", slug: "admin-fwd", min_role_to_post: "admin"})

      assert {:error, :cannot_post} =
               Content.forward_article_to_board(article, restricted, author)
    end
  end

  # --- Remove Article from Board ---

  describe "remove_article_from_board/3" do
    setup do
      author = create_user("user")
      admin = create_user("admin")
      other = create_user("user")

      board1 =
        create_board(%{name: "Board R1", slug: "board-r1-#{System.unique_integer([:positive])}"})

      board2 =
        create_board(%{name: "Board R2", slug: "board-r2-#{System.unique_integer([:positive])}"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Multi-board Article",
            body: "body",
            slug: "multi-board-#{System.unique_integer([:positive])}",
            user_id: author.id
          },
          [board1.id, board2.id]
        )

      %{
        author: author,
        admin: admin,
        other: other,
        board1: board1,
        board2: board2,
        article: article
      }
    end

    test "author can remove article from a board", %{
      author: author,
      board1: board1,
      article: article
    } do
      assert {:ok, updated} = Content.remove_article_from_board(article, board1, author)
      assert length(updated.boards) == 1
      refute Enum.any?(updated.boards, &(&1.id == board1.id))
    end

    test "admin can remove article from a board", %{
      admin: admin,
      board1: board1,
      article: article
    } do
      assert {:ok, updated} = Content.remove_article_from_board(article, board1, admin)
      assert length(updated.boards) == 1
    end

    test "other user cannot remove article from a board", %{
      other: other,
      board1: board1,
      article: article
    } do
      assert {:error, :unauthorized} = Content.remove_article_from_board(article, board1, other)
    end

    test "removing from all boards makes article boardless", %{
      author: author,
      board1: board1,
      board2: board2,
      article: article
    } do
      assert {:ok, updated} = Content.remove_article_from_board(article, board1, author)
      assert {:ok, final} = Content.remove_article_from_board(updated, board2, author)
      assert final.boards == []
    end

    test "returns error when article is not in the board", %{author: author, article: article} do
      other_board =
        create_board(%{name: "Other", slug: "other-rm-#{System.unique_integer([:positive])}"})

      assert {:error, :not_in_board} =
               Content.remove_article_from_board(article, other_board, author)
    end
  end

  # --- Can Forward Article ---

  describe "can_forward_article?/2" do
    test "author can forward" do
      author = create_user("user")

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Author FWD",
            body: "body",
            slug: "author-fwd-#{System.unique_integer([:positive])}",
            user_id: author.id
          },
          []
        )

      assert Content.can_forward_article?(author, article)
    end

    test "admin can forward" do
      author = create_user("user")
      admin = create_user("admin")

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Admin FWD",
            body: "body",
            slug: "admin-fwd-#{System.unique_integer([:positive])}",
            user_id: author.id
          },
          []
        )

      assert Content.can_forward_article?(admin, article)
    end

    test "other user cannot forward" do
      author = create_user("user")
      other = create_user("user")

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Other FWD",
            body: "body",
            slug: "other-fwd-#{System.unique_integer([:positive])}",
            user_id: author.id
          },
          []
        )

      refute Content.can_forward_article?(other, article)
    end
  end

  # --- Bookmarks ---

  describe "bookmark_article/2" do
    test "creates a bookmark for an article" do
      user = create_user("user")

      board =
        create_board(%{name: "BM Board", slug: "bm-board-#{System.unique_integer([:positive])}"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Bookmarkable",
            body: "body",
            slug: "bookmarkable-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      assert {:ok, bookmark} = Content.bookmark_article(user.id, article.id)
      assert bookmark.user_id == user.id
      assert bookmark.article_id == article.id
      assert is_nil(bookmark.comment_id)
    end

    test "returns error on duplicate bookmark" do
      user = create_user("user")

      board =
        create_board(%{
          name: "BM Board2",
          slug: "bm-board2-#{System.unique_integer([:positive])}"
        })

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Dup BM",
            body: "body",
            slug: "dup-bm-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      assert {:ok, _} = Content.bookmark_article(user.id, article.id)
      assert {:error, changeset} = Content.bookmark_article(user.id, article.id)
      assert errors_on(changeset)[:user_id] != nil || errors_on(changeset)[:article_id] != nil
    end
  end

  describe "bookmark_comment/2" do
    test "creates a bookmark for a comment" do
      user = create_user("user")

      board =
        create_board(%{
          name: "BM CBoard",
          slug: "bm-cboard-#{System.unique_integer([:positive])}"
        })

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Comment Article",
            body: "body",
            slug: "comment-art-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "A comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      assert {:ok, bookmark} = Content.bookmark_comment(user.id, comment.id)
      assert bookmark.comment_id == comment.id
      assert is_nil(bookmark.article_id)
    end
  end

  describe "delete_bookmark/2" do
    test "removes own bookmark" do
      user = create_user("user")

      board =
        create_board(%{
          name: "Del BM Board",
          slug: "del-bm-board-#{System.unique_integer([:positive])}"
        })

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Del BM",
            body: "body",
            slug: "del-bm-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, bookmark} = Content.bookmark_article(user.id, article.id)
      assert {:ok, _} = Content.delete_bookmark(user.id, bookmark.id)
      refute Content.article_bookmarked?(user.id, article.id)
    end

    test "ignores other user's bookmark" do
      user1 = create_user("user")
      user2 = create_user("user")

      board =
        create_board(%{
          name: "Oth BM Board",
          slug: "oth-bm-board-#{System.unique_integer([:positive])}"
        })

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Oth BM",
            body: "body",
            slug: "oth-bm-#{System.unique_integer([:positive])}",
            user_id: user1.id
          },
          [board.id]
        )

      {:ok, bookmark} = Content.bookmark_article(user1.id, article.id)
      assert {:error, :not_found} = Content.delete_bookmark(user2.id, bookmark.id)
      assert Content.article_bookmarked?(user1.id, article.id)
    end
  end

  describe "article_bookmarked?/2" do
    test "returns true/false correctly" do
      user = create_user("user")

      board =
        create_board(%{name: "AB Board", slug: "ab-board-#{System.unique_integer([:positive])}"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "AB Test",
            body: "body",
            slug: "ab-test-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      refute Content.article_bookmarked?(user.id, article.id)
      {:ok, _} = Content.bookmark_article(user.id, article.id)
      assert Content.article_bookmarked?(user.id, article.id)
    end
  end

  describe "toggle_article_bookmark/2" do
    test "creates then removes bookmark" do
      user = create_user("user")

      board =
        create_board(%{
          name: "Toggle Board",
          slug: "toggle-board-#{System.unique_integer([:positive])}"
        })

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Toggle BM",
            body: "body",
            slug: "toggle-bm-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      # First toggle: creates
      assert {:ok, %Baudrate.Content.Bookmark{}} =
               Content.toggle_article_bookmark(user.id, article.id)

      assert Content.article_bookmarked?(user.id, article.id)

      # Second toggle: removes
      assert {:ok, :removed} = Content.toggle_article_bookmark(user.id, article.id)
      refute Content.article_bookmarked?(user.id, article.id)
    end
  end

  describe "list_bookmarks/2" do
    test "returns paginated bookmarks" do
      user = create_user("user")

      board =
        create_board(%{
          name: "List BM Board",
          slug: "list-bm-board-#{System.unique_integer([:positive])}"
        })

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "List BM",
            body: "body",
            slug: "list-bm-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, _} = Content.bookmark_article(user.id, article.id)
      result = Content.list_bookmarks(user.id)

      assert length(result.bookmarks) == 1
      assert result.page == 1
      assert result.total_pages == 1
      assert hd(result.bookmarks).article.title == "List BM"
    end

    test "excludes soft-deleted articles" do
      user = create_user("user")

      board =
        create_board(%{name: "SD Board", slug: "sd-board-#{System.unique_integer([:positive])}"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Will Delete",
            body: "body",
            slug: "will-delete-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, _} = Content.bookmark_article(user.id, article.id)
      Content.soft_delete_article(article)

      result = Content.list_bookmarks(user.id)
      assert result.bookmarks == []
    end

    test "excludes soft-deleted comments" do
      user = create_user("user")

      board =
        create_board(%{
          name: "SDC Board",
          slug: "sdc-board-#{System.unique_integer([:positive])}"
        })

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "SDC Art",
            body: "body",
            slug: "sdc-art-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "Deletable comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      {:ok, _} = Content.bookmark_comment(user.id, comment.id)
      Content.soft_delete_comment(comment)

      result = Content.list_bookmarks(user.id)
      assert result.bookmarks == []
    end
  end

  describe "read tracking" do
    test "mark_article_read creates a read record" do
      user = create_user("user")
      board = create_board(%{name: "Read Board", slug: "read-board"})

      {:ok, %{article: article}} =
        Content.create_article(%{title: "A1", body: "b", slug: "a1", user_id: user.id}, [
          board.id
        ])

      assert {:ok, read} = Content.mark_article_read(user.id, article.id)
      assert read.user_id == user.id
      assert read.article_id == article.id
      assert read.read_at
    end

    test "mark_article_read upserts on repeated visits" do
      user = create_user("user")
      board = create_board(%{name: "Read Board 2", slug: "read-board-2"})

      {:ok, %{article: article}} =
        Content.create_article(%{title: "A2", body: "b", slug: "a2", user_id: user.id}, [
          board.id
        ])

      {:ok, read1} = Content.mark_article_read(user.id, article.id)
      # Force an earlier read_at so the upsert is visible
      Repo.update_all(
        from(ar in Baudrate.Content.ArticleRead, where: ar.id == ^read1.id),
        set: [read_at: ~U[2020-01-01 00:00:00Z]]
      )

      {:ok, read2} = Content.mark_article_read(user.id, article.id)
      assert read2.id == read1.id
      assert DateTime.compare(read2.read_at, ~U[2020-01-01 00:00:00Z]) == :gt
    end

    test "mark_board_read creates/upserts a board read record" do
      user = create_user("user")
      board = create_board(%{name: "Read Board 3", slug: "read-board-3"})

      assert {:ok, br} = Content.mark_board_read(user.id, board.id)
      assert br.user_id == user.id
      assert br.board_id == board.id
      assert br.read_at

      # Upsert
      Repo.update_all(
        from(b in Baudrate.Content.BoardRead, where: b.id == ^br.id),
        set: [read_at: ~U[2020-01-01 00:00:00Z]]
      )

      {:ok, br2} = Content.mark_board_read(user.id, board.id)
      assert br2.id == br.id
      assert DateTime.compare(br2.read_at, ~U[2020-01-01 00:00:00Z]) == :gt
    end

    test "unread_article_ids returns unread articles" do
      user = create_user("user")
      board = create_board(%{name: "Unread Board", slug: "unread-board"})

      # Move user registration to the past so activity timestamps work reliably
      past_registration = DateTime.add(DateTime.utc_now(), -3600, :second)

      Repo.update_all(
        from(u in Baudrate.Setup.User, where: u.id == ^user.id),
        set: [inserted_at: past_registration]
      )

      user = %{user | inserted_at: past_registration}

      {:ok, %{article: a1}} =
        Content.create_article(%{title: "U1", body: "b", slug: "u1", user_id: user.id}, [
          board.id
        ])

      {:ok, %{article: a2}} =
        Content.create_article(%{title: "U2", body: "b", slug: "u2", user_id: user.id}, [
          board.id
        ])

      # Activity is 30 min ago — after registration (1h ago) but before now
      activity_time =
        DateTime.add(DateTime.utc_now(), -1800, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(a in Article, where: a.id in ^[a1.id, a2.id]),
        set: [last_activity_at: activity_time]
      )

      unread = Content.unread_article_ids(user, [a1.id, a2.id], board.id)
      assert MapSet.member?(unread, a1.id)
      assert MapSet.member?(unread, a2.id)

      # Mark a1 as read — read_at = now() which is after activity_time
      Content.mark_article_read(user.id, a1.id)
      unread = Content.unread_article_ids(user, [a1.id, a2.id], board.id)
      refute MapSet.member?(unread, a1.id)
      assert MapSet.member?(unread, a2.id)
    end

    test "unread_article_ids respects board_read floor" do
      user = create_user("user")
      board = create_board(%{name: "Floor Board", slug: "floor-board"})

      # Move user registration to the past
      past_registration = DateTime.add(DateTime.utc_now(), -3600, :second)

      Repo.update_all(
        from(u in Baudrate.Setup.User, where: u.id == ^user.id),
        set: [inserted_at: past_registration]
      )

      user = %{user | inserted_at: past_registration}

      {:ok, %{article: a1}} =
        Content.create_article(%{title: "F1", body: "b", slug: "f1", user_id: user.id}, [
          board.id
        ])

      # Activity 30 min ago — after registration but before now
      activity_time =
        DateTime.add(DateTime.utc_now(), -1800, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(a in Article, where: a.id == ^a1.id),
        set: [last_activity_at: activity_time]
      )

      unread = Content.unread_article_ids(user, [a1.id], board.id)
      assert MapSet.member?(unread, a1.id)

      # Mark board as read — read_at = now() which is after activity_time
      Content.mark_board_read(user.id, board.id)

      unread = Content.unread_article_ids(user, [a1.id], board.id)
      assert MapSet.equal?(unread, MapSet.new())
    end

    test "unread_article_ids returns empty for guests" do
      assert Content.unread_article_ids(nil, [1, 2, 3], 1) == MapSet.new()
    end

    test "unread_board_ids identifies boards with unread articles" do
      user = create_user("user")
      board1 = create_board(%{name: "BU1", slug: "bu1"})
      board2 = create_board(%{name: "BU2", slug: "bu2"})

      # Move user registration to the past
      past_registration = DateTime.add(DateTime.utc_now(), -3600, :second)

      Repo.update_all(
        from(u in Baudrate.Setup.User, where: u.id == ^user.id),
        set: [inserted_at: past_registration]
      )

      user = %{user | inserted_at: past_registration}

      {:ok, %{article: _a1}} =
        Content.create_article(%{title: "BU1A", body: "b", slug: "bu1a", user_id: user.id}, [
          board1.id
        ])

      # Activity 30 min ago — after registration but before now
      activity_time =
        DateTime.add(DateTime.utc_now(), -1800, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(a in Article,
          join: ba in Baudrate.Content.BoardArticle,
          on: ba.article_id == a.id,
          where: ba.board_id == ^board1.id
        ),
        set: [last_activity_at: activity_time]
      )

      # Board2 has no articles — should not be unread
      unread = Content.unread_board_ids(user, [board1.id, board2.id])
      assert MapSet.member?(unread, board1.id)
      refute MapSet.member?(unread, board2.id)
    end

    test "parent board is unread when sub-board has unread articles" do
      user = create_user("user")
      parent = create_board(%{name: "Parent", slug: "parent-board"})
      child = create_board(%{name: "Child", slug: "child-board", parent_id: parent.id})

      # Move user registration to the past
      past_registration = DateTime.add(DateTime.utc_now(), -3600, :second)

      Repo.update_all(
        from(u in Baudrate.Setup.User, where: u.id == ^user.id),
        set: [inserted_at: past_registration]
      )

      user = %{user | inserted_at: past_registration}

      # Create article in child board only
      {:ok, %{article: _article}} =
        Content.create_article(
          %{title: "Child Art", body: "b", slug: "child-art", user_id: user.id},
          [child.id]
        )

      # Set activity 30 min ago — after registration but before now
      activity_time =
        DateTime.add(DateTime.utc_now(), -1800, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(a in Article,
          join: ba in Baudrate.Content.BoardArticle,
          on: ba.article_id == a.id,
          where: ba.board_id == ^child.id
        ),
        set: [last_activity_at: activity_time]
      )

      # Parent board should be marked unread because child board has unread articles
      unread = Content.unread_board_ids(user, [parent.id])
      assert MapSet.member?(unread, parent.id)
    end

    test "articles before user registration are treated as read" do
      board = create_board(%{name: "Old Board", slug: "old-board"})
      old_user = create_user("user")

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Old", body: "b", slug: "old-art", user_id: old_user.id},
          [board.id]
        )

      # Set article activity to the past (before any user registration)
      past = ~U[2020-01-01 00:00:00Z]

      Repo.update_all(
        from(a in Article, where: a.id == ^article.id),
        set: [last_activity_at: past]
      )

      # New user registers — article should be read (activity before registration)
      new_user = create_user("user")
      unread = Content.unread_article_ids(new_user, [article.id], board.id)
      assert MapSet.equal?(unread, MapSet.new())
    end
  end
end
