defmodule BaudrateWeb.BookmarksLiveTest do
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
      |> Board.changeset(%{name: "BM Board", slug: "bm-board"})
      |> Repo.insert!()

    {:ok, conn: conn, user: user, board: board}
  end

  test "shows empty state when no bookmarks", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/bookmarks")
    assert html =~ "No bookmarks yet."
  end

  test "lists bookmarked articles", %{conn: conn, user: user, board: board} do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Bookmarked Article",
          body: "body",
          slug: "bookmarked-article",
          user_id: user.id
        },
        [board.id]
      )

    Content.bookmark_article(user.id, article.id)

    {:ok, _lv, html} = live(conn, "/bookmarks")
    assert html =~ "Bookmarked Article"
  end

  test "remove bookmark via button", %{conn: conn, user: user, board: board} do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Remove Me",
          body: "body",
          slug: "remove-me-bm",
          user_id: user.id
        },
        [board.id]
      )

    Content.bookmark_article(user.id, article.id)

    {:ok, lv, html} = live(conn, "/bookmarks")
    assert html =~ "Remove Me"

    lv |> element(~s|button[phx-click="remove_bookmark"]|) |> render_click()
    html = render(lv)
    assert html =~ "Bookmark removed."
    assert html =~ "No bookmarks yet."
  end

  test "lists bookmarked comments", %{conn: conn, user: user, board: board} do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Comment Parent",
          body: "body",
          slug: "comment-parent-bm",
          user_id: user.id
        },
        [board.id]
      )

    {:ok, comment} =
      Content.create_comment(%{
        "body" => "A bookmarked comment",
        "article_id" => article.id,
        "user_id" => user.id
      })

    Content.bookmark_comment(user.id, comment.id)

    {:ok, _lv, html} = live(conn, "/bookmarks")
    assert html =~ "A bookmarked comment"
  end
end
