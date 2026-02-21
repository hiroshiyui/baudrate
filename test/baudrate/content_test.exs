defmodule Baudrate.ContentTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{Board, Article}
  alias Baudrate.Setup

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
