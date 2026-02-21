defmodule BaudrateWeb.BoardLiveTest do
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
      |> Board.changeset(%{name: "General", slug: "general"})
      |> Repo.insert!()

    {:ok, conn: conn, user: user, board: board}
  end

  test "renders board page with pagination", %{conn: conn, user: user, board: board} do
    # Create 25 articles
    for i <- 1..25 do
      Content.create_article(
        %{title: "Article #{i}", body: "Body", slug: "pag-art-#{i}-#{System.unique_integer([:positive])}", user_id: user.id},
        [board.id]
      )
    end

    {:ok, lv, html} = live(conn, "/boards/general")

    # Should show pagination
    assert html =~ "General"
    # DaisyUI join buttons
    assert html =~ "join-item"
  end

  test "navigates between pages", %{conn: conn, user: user, board: board} do
    for i <- 1..25 do
      Content.create_article(
        %{title: "Article #{i}", body: "Body", slug: "nav-art-#{i}-#{System.unique_integer([:positive])}", user_id: user.id},
        [board.id]
      )
    end

    {:ok, lv, _html} = live(conn, "/boards/general?page=2")

    # Should be on page 2
    assert render(lv) =~ "btn-active"
  end
end
