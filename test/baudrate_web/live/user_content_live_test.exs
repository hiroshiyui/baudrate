defmodule BaudrateWeb.UserContentLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Content
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  defp create_article(user, board, title) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          "title" => title,
          "body" => "Body of #{title}",
          "slug" => "art-#{System.unique_integer([:positive])}",
          "user_id" => user.id
        },
        [board.id]
      )

    article
  end

  defp create_comment(user, article, body) do
    {:ok, comment} =
      Content.create_comment(%{
        "body" => body,
        "article_id" => article.id,
        "user_id" => user.id
      })

    comment
  end

  describe "articles page" do
    test "renders articles list for user", %{conn: conn} do
      user = setup_user("user")

      {:ok, board} =
        Content.create_board(%{
          name: "Test Board",
          slug: "test-#{System.unique_integer([:positive])}"
        })

      create_article(user, board, "My First Article")

      {:ok, _lv, html} = live(conn, "/users/#{user.username}/articles")
      assert html =~ "My First Article"
      assert html =~ "Test Board"
      assert html =~ "Back to profile"
    end

    test "shows empty state when user has no articles", %{conn: conn} do
      user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/users/#{user.username}/articles")
      assert html =~ "No articles yet."
    end

    test "excludes deleted articles", %{conn: conn} do
      user = setup_user("user")

      {:ok, board} =
        Content.create_board(%{
          name: "Board",
          slug: "board-#{System.unique_integer([:positive])}"
        })

      article = create_article(user, board, "Deleted Article")
      Content.soft_delete_article(article)

      {:ok, _lv, html} = live(conn, "/users/#{user.username}/articles")
      refute html =~ "Deleted Article"
      assert html =~ "No articles yet."
    end
  end

  describe "comments page" do
    test "renders comments list for user", %{conn: conn} do
      user = setup_user("user")

      {:ok, board} =
        Content.create_board(%{
          name: "Board",
          slug: "board-#{System.unique_integer([:positive])}"
        })

      article = create_article(user, board, "Parent Article")
      create_comment(user, article, "My test comment body")

      {:ok, _lv, html} = live(conn, "/users/#{user.username}/comments")
      assert html =~ "My test comment body"
      assert html =~ "Parent Article"
      assert html =~ "Back to profile"
    end

    test "shows empty state when user has no comments", %{conn: conn} do
      user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/users/#{user.username}/comments")
      assert html =~ "No comments yet."
    end
  end

  describe "redirects" do
    test "redirects for nonexistent user", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, "/users/doesnotexist999/articles")
    end

    test "redirects for banned user", %{conn: conn} do
      admin = setup_user("admin")
      user = setup_user("user")
      {:ok, _, _} = Baudrate.Auth.ban_user(user, admin.id, "test")

      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, "/users/#{user.username}/articles")
    end
  end

  describe "stats links on user profile" do
    test "user profile stats link to articles and comments pages", %{conn: conn} do
      user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      assert html =~ ~s(href="/users/#{user.username}/articles")
      assert html =~ ~s(href="/users/#{user.username}/comments")
    end
  end

  describe "stats links on feed" do
    test "feed sidebar stats link to articles and comments pages", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ ~s(href="/users/#{user.username}/articles")
      assert html =~ ~s(href="/users/#{user.username}/comments")
    end
  end
end
