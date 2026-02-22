defmodule BaudrateWeb.Admin.BoardsLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Content
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  test "admin can view boards page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/boards")
    assert html =~ "Board Management"
  end

  test "non-admin is redirected away", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/boards")
  end

  test "admin can open new board form", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/boards")
    html = lv |> element("button[phx-click=\"new\"]") |> render_click()
    assert html =~ "New Board"
  end

  test "admin can create a board", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/boards")
    lv |> element("button[phx-click=\"new\"]") |> render_click()

    slug = "test-board-#{System.unique_integer([:positive])}"

    html =
      lv
      |> form("form", board: %{name: "Test Board", slug: slug, min_role_to_view: "guest", min_role_to_post: "user", position: 1})
      |> render_submit()

    assert html =~ "Board created successfully"
    assert html =~ "Test Board"
  end

  test "admin can edit a board", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, board} = Content.create_board(%{name: "Edit Me", slug: "edit-me-#{System.unique_integer([:positive])}"})

    {:ok, lv, _html} = live(conn, "/admin/boards")
    lv |> element("button[phx-click=\"edit\"][phx-value-id=\"#{board.id}\"]") |> render_click()

    html =
      lv
      |> form("form", board: %{name: "Edited Name"})
      |> render_submit()

    assert html =~ "Board updated successfully"
    assert html =~ "Edited Name"
  end

  test "admin can delete an empty board", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, board} = Content.create_board(%{name: "Delete Me", slug: "delete-me-#{System.unique_integer([:positive])}"})

    {:ok, lv, _html} = live(conn, "/admin/boards")

    html = lv |> element("button[phx-click=\"delete\"][phx-value-id=\"#{board.id}\"]") |> render_click()
    assert html =~ "Board deleted successfully"
    refute html =~ "Delete Me"
  end

  test "admin cannot delete board with articles", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, board} = Content.create_board(%{name: "Busy Board", slug: "busy-#{System.unique_integer([:positive])}"})

    # Create article linked to this board
    alias Baudrate.Content.{Article, BoardArticle}
    user = setup_user("user")

    {:ok, article} =
      %Article{}
      |> Article.changeset(%{
        title: "Test",
        body: "Body",
        slug: "art-#{System.unique_integer([:positive])}",
        user_id: user.id
      })
      |> Repo.insert()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.insert!(%BoardArticle{board_id: board.id, article_id: article.id, inserted_at: now, updated_at: now})

    {:ok, lv, _html} = live(conn, "/admin/boards")

    html = lv |> element("button[phx-click=\"delete\"][phx-value-id=\"#{board.id}\"]") |> render_click()
    assert html =~ "Cannot delete board that has articles"
  end

  test "admin cannot delete board with children", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, parent} = Content.create_board(%{name: "Parent Board", slug: "parent-#{System.unique_integer([:positive])}"})
    {:ok, _child} = Content.create_board(%{name: "Child Board", slug: "child-#{System.unique_integer([:positive])}", parent_id: parent.id})

    {:ok, lv, _html} = live(conn, "/admin/boards")

    html = lv |> element("button[phx-click=\"delete\"][phx-value-id=\"#{parent.id}\"]") |> render_click()
    assert html =~ "Cannot delete board that has sub-boards"
  end

  test "admin can cancel form", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/boards")
    lv |> element("button[phx-click=\"new\"]") |> render_click()

    html = lv |> element("button[phx-click=\"cancel\"]") |> render_click()
    refute html =~ "card-title"
  end
end
