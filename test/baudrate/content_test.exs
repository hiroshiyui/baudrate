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
end
