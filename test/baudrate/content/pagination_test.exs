defmodule Baudrate.Content.PaginationTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.Board
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
end
