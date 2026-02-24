defmodule BaudrateWeb.ArticleEditLiveTest do
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
      |> Board.changeset(%{name: "General", slug: "general-edit"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "My Article",
          body: "Original body",
          slug: "edit-test-article",
          user_id: user.id
        },
        [board.id]
      )

    {:ok, conn: conn, user: user, board: board, article: article}
  end

  test "renders edit form for article author", %{conn: conn, article: article} do
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}/edit")
    assert html =~ "Edit Article"
    assert html =~ "My Article"
    assert html =~ "Original body"
  end

  test "updates article successfully", %{conn: conn, article: article} do
    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}/edit")

    lv
    |> form("form", article: %{title: "Updated Title", body: "Updated body"})
    |> render_submit()

    {path, _flash} = assert_redirect(lv)
    assert path =~ "/articles/#{article.slug}"

    updated = Content.get_article_by_slug!(article.slug)
    assert updated.title == "Updated Title"
    assert updated.body == "Updated body"
  end

  test "redirects unauthorized user", %{conn: _conn, article: article} do
    other_user = setup_user("user")

    conn =
      Phoenix.ConnTest.build_conn()
      |> log_in_user(other_user)

    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             live(conn, "/articles/#{article.slug}/edit")

    assert to =~ "/articles/#{article.slug}"
    assert flash["error"] =~ "not authorized"
  end

  test "validate updates form without persisting", %{conn: conn, article: article} do
    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}/edit")

    html =
      lv
      |> form("form", article: %{title: "New Title", body: "New body"})
      |> render_change()

    assert html =~ "New Title"
    # DB unchanged
    db_article = Content.get_article_by_slug!(article.slug)
    assert db_article.title == "My Article"
    assert db_article.body == "Original body"
  end

  test "validate shows errors for blank title", %{conn: conn, article: article} do
    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}/edit")

    html =
      lv
      |> form("form", article: %{title: "", body: "Some body"})
      |> render_change()

    assert html =~ "t be blank" or html =~ "required"
  end

  test "admin can edit another user's article", %{conn: _conn, article: article} do
    admin = setup_user("admin")

    conn =
      Phoenix.ConnTest.build_conn()
      |> log_in_user(admin)

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}/edit")
    assert html =~ "Edit Article"
    assert html =~ "My Article"
  end
end
