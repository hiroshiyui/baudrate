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
      |> Board.changeset(%{name: "Public", slug: "public-search", min_role_to_view: "guest"})
      |> Repo.insert!()

    {:ok, conn: conn, user: user, board: board}
  end

  test "renders search page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/search")
    assert html =~ "Search"
    refute html =~ "Search Articles"
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

  test "default tab is articles", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/search?q=test")
    assert html =~ "tab-active"
    assert html =~ "Articles"
    assert html =~ ~s(role="tablist")
    assert html =~ ~s(aria-label="Search results")
    assert html =~ ~s(aria-selected="true")
  end

  test "switching to comments tab", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/search?q=test&tab=comments")
    html = render(lv)
    assert html =~ "No comments found"
  end

  test "comment search shows results with article title link", %{conn: conn, user: user, board: board} do
    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Searchable Article Title", body: "body", slug: "searchable-art", user_id: user.id},
        [board.id]
      )

    {:ok, _} =
      Content.create_comment(%{
        "body" => "A unique searchable comment text here",
        "article_id" => article.id,
        "user_id" => user.id
      })

    {:ok, lv, _html} = live(conn, "/search?q=unique+searchable&tab=comments")
    html = render(lv)
    assert html =~ "Searchable Article Title"
    assert html =~ "unique searchable comment"
  end

  test "CJK search returns results on articles tab", %{conn: conn, user: user, board: board} do
    {:ok, _} =
      Content.create_article(
        %{title: "Elixir入門ガイド", body: "プログラミング言語", slug: "cjk-art", user_id: user.id},
        [board.id]
      )

    {:ok, _lv, html} = live(conn, "/search?q=入門")
    assert html =~ "Elixir入門ガイド"
  end

  test "CJK search returns results on comments tab", %{conn: conn, user: user, board: board} do
    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "CJK Art", body: "body", slug: "cjk-cmt-art", user_id: user.id},
        [board.id]
      )

    {:ok, _} =
      Content.create_comment(%{
        "body" => "これは検索テストです",
        "article_id" => article.id,
        "user_id" => user.id
      })

    {:ok, _lv, html} = live(conn, "/search?q=検索テスト&tab=comments")
    assert html =~ "検索テスト"
  end

  test "empty comment search shows no-results message", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/search?q=zzzznonexistent&tab=comments")
    assert html =~ "No comments found"
  end

  test "tab persists through search submission", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/search?q=old&tab=comments")

    lv
    |> form("form", q: "new")
    |> render_submit()

    assert_patch(lv)
    html = render(lv)
    assert html =~ "No comments found"
  end
end
