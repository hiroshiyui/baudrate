defmodule BaudrateWeb.ArticleLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)

    board =
      %Board{}
      |> Board.changeset(%{name: "General", slug: "general-art"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Test Article", body: "Article body text", slug: "test-article", user_id: user.id},
        [board.id]
      )

    {:ok, conn: conn, user: user, board: board, article: article}
  end

  test "renders article with edit/delete buttons for author", %{conn: conn, article: article} do
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Test Article"
    assert html =~ "Edit"
    assert html =~ "Delete"
  end

  test "does not show edit/delete for non-author", %{article: article} do
    Repo.insert!(%Setting{key: "registration_mode", value: "open"})
    other_user = setup_user("user")

    conn =
      Phoenix.ConnTest.build_conn()
      |> log_in_user(other_user)

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Test Article"
    refute html =~ "hero-pencil-square"
  end

  test "deletes article and redirects", %{conn: conn, article: article} do
    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

    lv |> element("button[phx-click=delete_article]") |> render_click()

    assert_redirect(lv)
  end

  test "renders comment section", %{conn: conn, article: article} do
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Comments"
    assert html =~ "Write a comment"
  end

  test "posts a comment", %{conn: conn, article: article} do
    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

    html =
      lv
      |> form("form[phx-submit=submit_comment]", comment: %{body: "Great article!"})
      |> render_submit()

    assert html =~ "Great article!"
  end
end
