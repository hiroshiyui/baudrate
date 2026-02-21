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

      {:ok, %{article: _pinned}} =
        Content.create_article(
          %{title: "Pinned", body: "b", slug: "pinned", user_id: user.id, pinned: true},
          [board.id]
        )

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

  # --- SysOp Board ---

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
