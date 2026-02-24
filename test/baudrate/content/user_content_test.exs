defmodule Baudrate.Content.UserContentTest do
  use Baudrate.DataCase

  alias Baudrate.Content

  setup do
    user = setup_user("user")

    {:ok, board} =
      Content.create_board(%{name: "Test", slug: "test-#{System.unique_integer([:positive])}"})

    {:ok, user: user, board: board}
  end

  describe "list_recent_articles_by_user/2" do
    test "returns recent articles by user", %{user: user, board: board} do
      {:ok, %{article: _}} =
        Content.create_article(
          %{
            "title" => "Article 1",
            "body" => "Body",
            "slug" => "a1-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      articles = Content.list_recent_articles_by_user(user.id)
      assert length(articles) == 1
      assert hd(articles).title == "Article 1"
    end

    test "excludes deleted articles", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Deleted",
            "body" => "Body",
            "slug" => "del-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      Content.soft_delete_article(article)
      articles = Content.list_recent_articles_by_user(user.id)
      assert articles == []
    end
  end

  describe "count_articles_by_user/1" do
    test "counts non-deleted articles", %{user: user, board: board} do
      {:ok, _} =
        Content.create_article(
          %{
            "title" => "A1",
            "body" => "Body",
            "slug" => "ca1-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      assert Content.count_articles_by_user(user.id) == 1
    end
  end

  describe "count_comments_by_user/1" do
    test "counts non-deleted comments", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Art",
            "body" => "Body",
            "slug" => "cc-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      {:ok, _} =
        Content.create_comment(%{
          "body" => "Comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      assert Content.count_comments_by_user(user.id) == 1
    end
  end

  defp setup_user(role_name) do
    import Ecto.Query
    alias Baudrate.Repo
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "test_#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end
end
