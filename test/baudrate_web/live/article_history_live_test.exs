defmodule BaudrateWeb.ArticleHistoryLiveTest do
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
      |> Board.changeset(%{name: "General", slug: "general-hist"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Test Article", body: "Original body", slug: "hist-article", user_id: user.id},
        [board.id]
      )

    {:ok, conn: conn, user: user, board: board, article: article}
  end

  test "renders history page with revisions", %{conn: conn, user: user, article: article} do
    {:ok, _updated} =
      Content.update_article(article, %{title: "Updated Title", body: "Updated body"}, user)

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}/history")
    assert html =~ "Edit History"
    assert html =~ "Updated Title"
    assert html =~ user.username
    assert html =~ "#1"
  end

  test "shows empty state when no revisions exist", %{conn: conn, article: article} do
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}/history")
    assert html =~ "No edit history available."
  end

  test "shows diff when selecting a revision", %{conn: conn, user: user, article: article} do
    {:ok, a2} =
      Content.update_article(article, %{title: "Second Version", body: "Second body"}, user)

    {:ok, _a3} =
      Content.update_article(a2, %{title: "Third Version", body: "Third body"}, user)

    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}/history")

    # Select the newest revision (index 0)
    html = lv |> element("button[phx-value-index='0']") |> render_click()

    # Should show the revision content
    assert html =~ "Version #2"
  end

  test "shows full content for oldest revision (no previous to diff against)", %{
    conn: conn,
    user: user,
    article: article
  } do
    {:ok, _updated} =
      Content.update_article(article, %{title: "Edited", body: "Edited body"}, user)

    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}/history")

    # Select the only revision (index 0, the oldest)
    html = lv |> element("button[phx-value-index='0']") |> render_click()
    assert html =~ "Original body"
  end

  test "redirects guests on restricted board", %{user: user} do
    restricted_board =
      %Board{}
      |> Board.changeset(%{
        name: "Restricted",
        slug: "restricted-hist",
        min_role_to_view: "user"
      })
      |> Repo.insert!()

    {:ok, %{article: restricted_article}} =
      Content.create_article(
        %{title: "Secret", body: "body", slug: "secret-hist", user_id: user.id},
        [restricted_board.id]
      )

    # Guest conn (no auth)
    guest_conn = Phoenix.ConnTest.build_conn()

    assert {:error, {:redirect, %{to: "/login"}}} =
             live(guest_conn, "/articles/#{restricted_article.slug}/history")
  end

  test "article page shows history link when revisions exist", %{
    conn: conn,
    user: user,
    article: article
  } do
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    refute html =~ "hero-clock"

    {:ok, _updated} =
      Content.update_article(article, %{title: "Edited", body: "Edited body"}, user)

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "hero-clock"
  end

  test "back link navigates to article", %{conn: conn, user: user, article: article} do
    {:ok, _} =
      Content.update_article(article, %{title: "Edited", body: "Edited body"}, user)

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}/history")
    assert html =~ ~s(href="/articles/#{article.slug}")
    assert html =~ "Back to article"
  end
end
