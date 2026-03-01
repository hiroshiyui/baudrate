defmodule Baudrate.PaginationTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Pagination
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    import Ecto.Query
    role = Repo.one!(from r in Setup.Role, where: r.name == "user")

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

  defp create_board do
    slug = "board-#{System.unique_integer([:positive])}"

    %Board{}
    |> Board.changeset(%{name: "Board", slug: slug})
    |> Repo.insert!()
  end

  defp create_articles(board, user, count) do
    for i <- 1..count do
      slug = "article-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Article #{i}", body: "Body #{i}", slug: slug, user_id: user.id},
          [board.id]
        )

      article
    end
  end

  describe "paginate_articles_for_board/2" do
    test "returns first page with correct total" do
      user = create_user()
      board = create_board()
      create_articles(board, user, 25)

      result = Content.paginate_articles_for_board(board, page: 1, per_page: 10)

      assert length(result.articles) == 10
      assert result.total == 25
      assert result.page == 1
      assert result.per_page == 10
      assert result.total_pages == 3
    end

    test "returns correct second page" do
      user = create_user()
      board = create_board()
      create_articles(board, user, 25)

      page1 = Content.paginate_articles_for_board(board, page: 1, per_page: 10)
      page2 = Content.paginate_articles_for_board(board, page: 2, per_page: 10)

      assert length(page2.articles) == 10
      assert page2.page == 2

      # No overlap between pages
      ids1 = MapSet.new(page1.articles, & &1.id)
      ids2 = MapSet.new(page2.articles, & &1.id)
      assert MapSet.disjoint?(ids1, ids2)
    end

    test "returns partial last page" do
      user = create_user()
      board = create_board()
      create_articles(board, user, 25)

      result = Content.paginate_articles_for_board(board, page: 3, per_page: 10)
      assert length(result.articles) == 5
      assert result.page == 3
    end

    test "returns empty list for page beyond total" do
      user = create_user()
      board = create_board()
      create_articles(board, user, 5)

      result = Content.paginate_articles_for_board(board, page: 10, per_page: 10)
      assert result.articles == []
    end

    test "handles empty board" do
      board = create_board()

      result = Content.paginate_articles_for_board(board)
      assert result.articles == []
      assert result.total == 0
      assert result.total_pages == 1
    end

    test "clamps page to minimum of 1" do
      user = create_user()
      board = create_board()
      create_articles(board, user, 5)

      result = Content.paginate_articles_for_board(board, page: -1)
      assert result.page == 1
    end

    test "excludes soft-deleted articles" do
      user = create_user()
      board = create_board()
      articles = create_articles(board, user, 3)

      Content.soft_delete_article(hd(articles))

      result = Content.paginate_articles_for_board(board)
      assert result.total == 2
    end
  end

  describe "Pagination.paginate_opts/2" do
    test "returns defaults when opts are empty" do
      assert {1, 20, 0} = Pagination.paginate_opts([], 20)
    end

    test "uses provided page and per_page" do
      assert {3, 10, 20} = Pagination.paginate_opts([page: 3, per_page: 10], 20)
    end

    test "clamps page to minimum of 1" do
      assert {1, 20, 0} = Pagination.paginate_opts([page: 0], 20)
      assert {1, 20, 0} = Pagination.paginate_opts([page: -5], 20)
    end

    test "uses default_per_page when not specified" do
      assert {2, 15, 15} = Pagination.paginate_opts([page: 2], 15)
    end

    test "calculates correct offset" do
      assert {5, 10, 40} = Pagination.paginate_opts([page: 5, per_page: 10], 20)
    end
  end

  describe "Pagination.paginate_query/3" do
    test "returns correct pagination result map" do
      import Ecto.Query

      user = create_user()
      board = create_board()
      create_articles(board, user, 5)

      base_query =
        from(a in Content.Article,
          join: ba in Content.BoardArticle,
          on: ba.article_id == a.id,
          where: ba.board_id == ^board.id and is_nil(a.deleted_at),
          distinct: a.id
        )

      result =
        Pagination.paginate_query(base_query, {1, 2, 0},
          result_key: :articles,
          order_by: [desc: dynamic([q], q.inserted_at)],
          preloads: [:user]
        )

      assert result.total == 5
      assert result.page == 1
      assert result.per_page == 2
      assert result.total_pages == 3
      assert length(result.articles) == 2
    end

    test "returns partial last page" do
      import Ecto.Query

      user = create_user()
      board = create_board()
      create_articles(board, user, 5)

      base_query =
        from(a in Content.Article,
          join: ba in Content.BoardArticle,
          on: ba.article_id == a.id,
          where: ba.board_id == ^board.id and is_nil(a.deleted_at),
          distinct: a.id
        )

      result =
        Pagination.paginate_query(base_query, {3, 2, 4},
          result_key: :articles,
          order_by: [desc: dynamic([q], q.inserted_at)],
          preloads: [:user]
        )

      assert result.total == 5
      assert result.page == 3
      assert result.total_pages == 3
      assert length(result.articles) == 1
    end

    test "returns empty results for page beyond total" do
      import Ecto.Query

      user = create_user()
      board = create_board()
      create_articles(board, user, 5)

      base_query =
        from(a in Content.Article,
          join: ba in Content.BoardArticle,
          on: ba.article_id == a.id,
          where: ba.board_id == ^board.id and is_nil(a.deleted_at),
          distinct: a.id
        )

      result =
        Pagination.paginate_query(base_query, {10, 2, 18},
          result_key: :articles,
          order_by: [desc: dynamic([q], q.inserted_at)],
          preloads: []
        )

      assert result.total == 5
      assert result.page == 10
      assert result.articles == []
    end

    test "total_pages is at least 1 when no results" do
      import Ecto.Query

      base_query =
        from(a in Content.Article,
          where: a.id == -1,
          distinct: a.id
        )

      result =
        Pagination.paginate_query(base_query, {1, 20, 0},
          result_key: :articles,
          order_by: [desc: dynamic([q], q.inserted_at)],
          preloads: []
        )

      assert result.total == 0
      assert result.total_pages == 1
      assert result.articles == []
    end

    test "preloads associations" do
      import Ecto.Query

      user = create_user()
      board = create_board()
      create_articles(board, user, 1)

      base_query =
        from(a in Content.Article,
          join: ba in Content.BoardArticle,
          on: ba.article_id == a.id,
          where: ba.board_id == ^board.id and is_nil(a.deleted_at),
          distinct: a.id
        )

      result =
        Pagination.paginate_query(base_query, {1, 10, 0},
          result_key: :articles,
          order_by: [desc: dynamic([q], q.inserted_at)],
          preloads: [:user, :boards]
        )

      article = hd(result.articles)
      assert %Setup.User{} = article.user
      assert [%Board{} | _] = article.boards
    end

    test "page far beyond total returns empty results with correct metadata" do
      import Ecto.Query

      user = create_user()
      board = create_board()
      create_articles(board, user, 3)

      base_query =
        from(a in Content.Article,
          join: ba in Content.BoardArticle,
          on: ba.article_id == a.id,
          where: ba.board_id == ^board.id and is_nil(a.deleted_at),
          distinct: a.id
        )

      result =
        Pagination.paginate_query(base_query, {1000, 20, 19_980},
          result_key: :articles,
          order_by: [desc: dynamic([q], q.inserted_at)],
          preloads: []
        )

      assert result.articles == []
      assert result.total == 3
      assert result.page == 1000
      assert result.total_pages == 1
    end
  end
end
