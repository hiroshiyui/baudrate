defmodule BaudrateWeb.TagLiveTest do
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
      |> Board.changeset(%{
        name: "Tag Board",
        slug: "tag-board-#{System.unique_integer([:positive])}",
        min_role_to_view: "guest"
      })
      |> Repo.insert!()

    {:ok, conn: conn, user: user, board: board}
  end

  test "shows articles matching tag", %{conn: conn, user: user, board: board} do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Elixir Tutorial",
          body: "Learn #elixir programming",
          slug: "tag-art-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    Content.sync_article_tags(article)

    {:ok, _lv, html} = live(conn, ~p"/tags/elixir")

    assert html =~ "elixir"
    assert html =~ "Elixir Tutorial"
  end

  test "shows empty state when no articles match tag", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/tags/nonexistent")

    assert html =~ "No articles found"
  end

  test "board visibility respected — guest cannot see user-only board articles", %{
    user: user
  } do
    Repo.insert(%Setting{key: "setup_completed", value: "true"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    private_board =
      %Board{}
      |> Board.changeset(%{
        name: "Private Board",
        slug: "priv-tag-#{System.unique_integer([:positive])}",
        min_role_to_view: "user"
      })
      |> Repo.insert!()

    {:ok, %{article: priv_article}} =
      Content.create_article(
        %{
          title: "Private Tagged Article",
          body: "Secret #restricted content",
          slug: "priv-tag-art-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [private_board.id]
      )

    Content.sync_article_tags(priv_article)

    # Guest connection (no login)
    guest_conn = Phoenix.ConnTest.build_conn()
    {:ok, _lv, html} = live(guest_conn, ~p"/tags/restricted")

    refute html =~ "Private Tagged Article"
    assert html =~ "No articles found"
  end

  test "displays tag name in heading", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/tags/elixir")

    assert html =~ "elixir"
  end

  test "shows result count when articles exist", %{conn: conn, user: user, board: board} do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Tagged Post",
          body: "Content with #counting",
          slug: "count-tag-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    Content.sync_article_tags(article)

    {:ok, _lv, html} = live(conn, ~p"/tags/counting")

    assert html =~ "1 result"
  end
end
