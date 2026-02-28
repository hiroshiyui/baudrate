defmodule BaudrateWeb.ArticleNewLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Content.Board
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)

    board =
      %Board{}
      |> Board.changeset(%{name: "General", slug: "general"})
      |> Repo.insert!()

    {:ok, conn: conn, user: user, board: board}
  end

  test "renders article creation form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/articles/new")
    assert html =~ "Create Article"
    assert html =~ "Title"
    assert html =~ "Body"
  end

  test "renders form with pre-selected board", %{conn: conn, board: board} do
    {:ok, _lv, html} = live(conn, "/boards/#{board.slug}/articles/new")
    assert html =~ "Create Article"
    assert html =~ "General"
  end

  test "creates article successfully", %{conn: conn, board: board} do
    {:ok, lv, _html} = live(conn, "/articles/new")

    lv
    |> form("form", article: %{title: "Test Article", body: "Test body content"})
    |> render_submit(%{"board_ids" => ["#{board.id}"]})

    {path, _flash} = assert_redirect(lv)
    assert path =~ "/articles/"
  end

  test "shows error when no board selected", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/articles/new")

    html =
      lv
      |> form("form", article: %{title: "No Board", body: "Test body"})
      |> render_submit()

    assert html =~ "Please select at least one board"
  end

  test "renders form with DraftSaveHook and draft indicator", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/articles/new")
    assert html =~ ~s(phx-hook="DraftSaveHook")
    assert html =~ ~s(data-draft-key="draft:article:new")
    assert html =~ ~s(data-draft-fields="article[title],article[body]")
    assert html =~ "draft-indicator-new"
  end

  test "redirects pending user away from article creation", %{conn: _conn} do
    {:ok, pending_user, _codes} =
      Baudrate.Auth.register_user(%{
        "username" => "pendingwriter",
        "password" => "SecurePass1!!",
        "password_confirmation" => "SecurePass1!!",
        "terms_accepted" => "true"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> log_in_user(pending_user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/articles/new")
  end
end
