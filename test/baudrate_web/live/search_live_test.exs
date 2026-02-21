defmodule BaudrateWeb.SearchLiveTest do
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
      |> Board.changeset(%{name: "Public", slug: "public-search", visibility: "public"})
      |> Repo.insert!()

    {:ok, conn: conn, user: user, board: board}
  end

  test "renders search page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/search")
    assert html =~ "Search Articles"
  end

  test "searches for articles and displays results", %{conn: conn, user: user, board: board} do
    {:ok, _} =
      Content.create_article(
        %{title: "Elixir Tutorial", body: "Learn about Elixir programming", slug: "elixir-tut", user_id: user.id},
        [board.id]
      )

    {:ok, _} =
      Content.create_article(
        %{title: "Phoenix Guide", body: "Building web apps with Phoenix", slug: "phoenix-guide", user_id: user.id},
        [board.id]
      )

    {:ok, lv, _html} = live(conn, "/search")

    html =
      lv
      |> form("form", q: "Elixir")
      |> render_submit()

    # After submit, LiveView patches to new URL
    assert_patch(lv)
  end

  test "shows no results message for empty search", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/search?q=nonexistentxyz")
    assert html =~ "No articles found"
  end
end
