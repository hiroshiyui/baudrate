defmodule Baudrate.Content.SearchTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Repo
  alias Baudrate.Setup

  import Ecto.Query

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name \\ "user") do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "search_#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    %Board{}
    |> Board.changeset(
      Map.merge(
        %{
          name: "Board #{unique}",
          slug: "board-#{unique}",
          min_role_to_view: "guest",
          min_role_to_post: "user"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp create_article(user, board, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, %{article: article}} =
      Content.create_article(
        Map.merge(
          %{
            title: "Article #{unique}",
            body: "Body #{unique}",
            slug: "article-#{unique}",
            user_id: user.id
          },
          attrs
        ),
        [board.id]
      )

    article
  end

  defp create_comment(user, article, body) do
    {:ok, comment} =
      Content.create_comment(%{body: body, article_id: article.id, user_id: user.id})

    comment
  end

  describe "search_boards/2" do
    test "finds boards matching name" do
      user = create_user()
      board = create_board(%{name: "Elixir Discussion"})

      results = Content.search_boards("Elixir", user)
      assert Enum.any?(results, &(&1.id == board.id))
    end

    test "finds boards matching slug" do
      user = create_user()
      board = create_board(%{slug: "phoenix-forum"})

      results = Content.search_boards("phoenix", user)
      assert Enum.any?(results, &(&1.id == board.id))
    end

    test "returns empty list when no match" do
      user = create_user()
      _board = create_board(%{name: "General", slug: "general"})

      results = Content.search_boards("nonexistent_xyz", user)
      assert results == []
    end

    test "filters out boards the user cannot post in" do
      guest = create_user("guest")
      _board = create_board(%{name: "Mod Only Post", min_role_to_post: "moderator"})

      results = Content.search_boards("Mod Only", guest)
      assert results == []
    end

    test "admin can find boards with higher post requirements" do
      admin = create_user("admin")
      board = create_board(%{name: "Admin Posting", min_role_to_post: "admin"})

      results = Content.search_boards("Admin Posting", admin)
      assert Enum.any?(results, &(&1.id == board.id))
    end
  end

  describe "search_visible_boards/2" do
    test "finds boards matching name" do
      board = create_board(%{name: "Visible Board XYZ"})

      result = Content.search_visible_boards("Visible Board XYZ")
      assert Enum.any?(result.boards, &(&1.id == board.id))
      assert result.total >= 1
    end

    test "finds boards matching description" do
      board = create_board(%{name: "Some Board"})

      board
      |> Ecto.Changeset.change(description: "A unique description for testing search")
      |> Repo.update!()

      result = Content.search_visible_boards("unique description")
      assert Enum.any?(result.boards, &(&1.id == board.id))
    end

    test "returns paginated result structure" do
      result = Content.search_visible_boards("anything", page: 1, per_page: 5)

      assert Map.has_key?(result, :boards)
      assert Map.has_key?(result, :total)
      assert Map.has_key?(result, :page)
      assert Map.has_key?(result, :per_page)
      assert Map.has_key?(result, :total_pages)
      assert result.page == 1
      assert result.per_page == 5
    end

    test "guest cannot see boards with higher view requirements" do
      _board =
        create_board(%{name: "Secret Mod Board", min_role_to_view: "moderator"})

      result = Content.search_visible_boards("Secret Mod Board", user: nil)
      refute Enum.any?(result.boards, &(&1.name == "Secret Mod Board"))
    end

    test "authenticated user can see user-level boards" do
      user = create_user()
      board = create_board(%{name: "User Only Visible", min_role_to_view: "user"})

      result = Content.search_visible_boards("User Only Visible", user: user)
      assert Enum.any?(result.boards, &(&1.id == board.id))
    end
  end

  describe "search_articles/2" do
    test "finds articles by English full-text search" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "Phoenix framework guide", body: "Learn Phoenix"})

      result = Content.search_articles("Phoenix framework", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "finds articles by CJK ILIKE search" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "台灣科技論壇", body: "討論科技話題"})

      result = Content.search_articles("科技", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "returns empty for no match" do
      user = create_user()
      board = create_board()
      _article = create_article(user, board, %{title: "Test", body: "Content"})

      result = Content.search_articles("zzz_nonexistent_zzz", user: user)
      assert result.articles == []
      assert result.total == 0
    end

    test "excludes soft-deleted articles" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "Deletable post about Erlang", body: "Erlang content"})

      Content.soft_delete_article(article)

      result = Content.search_articles("Erlang", user: user)
      refute Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "respects board visibility for guests" do
      user = create_user()
      restricted_board = create_board(%{min_role_to_view: "moderator"})
      article = create_article(user, restricted_board, %{title: "Hidden moderator content", body: "Secret stuff"})

      result = Content.search_articles("moderator content", user: nil)
      refute Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "returns paginated result structure" do
      result = Content.search_articles("test", user: nil, page: 1, per_page: 10)

      assert Map.has_key?(result, :articles)
      assert Map.has_key?(result, :total)
      assert Map.has_key?(result, :page)
      assert Map.has_key?(result, :per_page)
      assert Map.has_key?(result, :total_pages)
    end

    test "author: operator filters by username" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "Author filtered post", body: "Content here"})

      other_user = create_user()
      _other_article = create_article(other_user, board, %{title: "Other author post", body: "Other content"})

      result = Content.search_articles("author:#{user.username}", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))
      refute Enum.any?(result.articles, &(&1.user_id == other_user.id))
    end

    test "board: operator filters by board slug" do
      user = create_user()
      board_a = create_board(%{slug: "board-alpha-#{System.unique_integer([:positive])}"})
      board_b = create_board(%{slug: "board-beta-#{System.unique_integer([:positive])}"})
      article_a = create_article(user, board_a)
      _article_b = create_article(user, board_b)

      result = Content.search_articles("board:#{board_a.slug}", user: user)
      assert Enum.any?(result.articles, &(&1.id == article_a.id))
    end

    test "tag: operator filters by tag" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "Tagged post", body: "Has #elixir tag"})

      Content.sync_article_tags(article)

      result = Content.search_articles("tag:elixir", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "before: operator filters articles before a date" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "Old article about Haskell", body: "Haskell content"})

      # Set article inserted_at to a past date
      past_date = ~U[2025-01-01 00:00:00Z]

      from(a in Content.Article, where: a.id == ^article.id)
      |> Repo.update_all(set: [inserted_at: past_date])

      result = Content.search_articles("before:2025-06-01", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))

      result = Content.search_articles("before:2024-12-31", user: user)
      refute Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "after: operator filters articles after a date" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "Recent article about Rust", body: "Rust content"})

      future_date = ~U[2026-06-01 00:00:00Z]

      from(a in Content.Article, where: a.id == ^article.id)
      |> Repo.update_all(set: [inserted_at: future_date])

      result = Content.search_articles("after:2026-05-01", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))

      result = Content.search_articles("after:2026-07-01", user: user)
      refute Enum.any?(result.articles, &(&1.id == article.id))
    end
  end

  describe "search_comments/2" do
    test "finds comments matching body text" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      comment = create_comment(user, article, "This is a unique comment about testing")

      result = Content.search_comments("unique comment", user: user)
      assert Enum.any?(result.comments, &(&1.id == comment.id))
    end

    test "returns empty for no match" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      _comment = create_comment(user, article, "Normal comment")

      result = Content.search_comments("zzz_nonexistent_zzz", user: user)
      assert result.comments == []
      assert result.total == 0
    end

    test "returns paginated result structure" do
      result = Content.search_comments("test", user: nil, page: 1, per_page: 10)

      assert Map.has_key?(result, :comments)
      assert Map.has_key?(result, :total)
      assert Map.has_key?(result, :page)
      assert Map.has_key?(result, :per_page)
      assert Map.has_key?(result, :total_pages)
    end

    test "respects board visibility" do
      user = create_user()
      restricted_board = create_board(%{min_role_to_view: "admin"})
      article = create_article(user, restricted_board)
      _comment = create_comment(user, article, "Hidden admin comment content")

      result = Content.search_comments("admin comment content", user: nil)
      assert result.comments == []
    end

    test "excludes comments on soft-deleted articles" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      _comment = create_comment(user, article, "Comment on deleted article xyz")

      Content.soft_delete_article(article)

      result = Content.search_comments("deleted article xyz", user: user)
      assert result.comments == []
    end

    test "excludes soft-deleted comments" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      comment = create_comment(user, article, "Soon to be deleted comment abc")

      Content.soft_delete_comment(comment)

      result = Content.search_comments("deleted comment abc", user: user)
      assert result.comments == []
    end
  end
end
