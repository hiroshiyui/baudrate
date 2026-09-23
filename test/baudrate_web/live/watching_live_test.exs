defmodule BaudrateWeb.WatchingLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")

    board =
      %Board{}
      |> Board.changeset(%{
        name: "Watched Board",
        slug: "wb-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Watched Thread",
          body: "Body",
          slug: "wt-#{System.unique_integer([:positive])}",
          user_id: setup_user("user").id
        },
        [board.id]
      )

    %{conn: log_in_user(conn, user), user: user, board: board, article: article}
  end

  test "requires signing in" do
    assert {:error, {:redirect, %{to: "/login" <> _}}} = live(build_conn(), "/watching")
  end

  test "the board toggle watches and says so", %{conn: conn, user: user, board: board} do
    {:ok, lv, _html} = live(conn, "/boards/#{board.slug}")
    assert has_element?(lv, ~s|#board-watch-toggle[aria-pressed="false"]|, "Watch")

    lv |> element("#board-watch-toggle") |> render_click()

    assert has_element?(lv, ~s|#board-watch-toggle[aria-pressed="true"]|, "Watching")
    assert Content.board_watched?(user, board.id)
  end

  test "the thread toggle watches and says so", %{conn: conn, user: user, article: article} do
    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")
    lv |> element("#article-watch-toggle") |> render_click()

    assert has_element?(lv, ~s|#article-watch-toggle[aria-pressed="true"]|)
    assert Content.article_watched?(user, article.id)
  end

  test "a guest has no toggle, and a forged event does nothing", %{board: board} do
    {:ok, lv, _html} = live(build_conn(), "/boards/#{board.slug}")
    refute has_element?(lv, "#board-watch-toggle")
    render_click(lv, "toggle_watch", %{})
  end

  test "lists what is watched and unwatches from the list", ctx do
    {:ok, board_watch} = Content.toggle_board_watch(ctx.user, ctx.board.id)
    {:ok, thread_watch} = Content.toggle_article_watch(ctx.user, ctx.article.id)

    {:ok, lv, _html} = live(ctx.conn, "/watching")
    assert has_element?(lv, "#watching-board-#{board_watch.id}", "Watched Board")
    assert has_element?(lv, "#watching-article-#{thread_watch.id}", "Watched Thread")

    lv |> element("#watching-board-unwatch-#{board_watch.id}") |> render_click()

    refute has_element?(lv, "#watching-board-#{board_watch.id}")
    refute Content.board_watched?(ctx.user, ctx.board.id)
    assert_push_event(lv, "focus", %{id: "watching-heading"})
  end

  test "a board the member can no longer open is listed without its name", ctx do
    {:ok, watch} = Content.toggle_board_watch(ctx.user, ctx.board.id)
    {:ok, _} = Content.update_board(ctx.board, %{min_role_to_view: "moderator"})

    {:ok, lv, _html} = live(ctx.conn, "/watching")

    assert has_element?(lv, "#watching-board-#{watch.id}", "A board you can no longer open")
    refute has_element?(lv, "#watching-board-#{watch.id}", "Watched Board")
    assert has_element?(lv, "#watching-board-unwatch-#{watch.id}")
  end
end
