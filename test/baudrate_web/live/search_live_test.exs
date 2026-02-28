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
        %{
          title: "Elixir Tutorial",
          body: "Learn about Elixir programming",
          slug: "elixir-tut",
          user_id: user.id
        },
        [board.id]
      )

    {:ok, _} =
      Content.create_article(
        %{
          title: "Phoenix Guide",
          body: "Building web apps with Phoenix",
          slug: "phoenix-guide",
          user_id: user.id
        },
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

  test "comment search shows results with article title link", %{
    conn: conn,
    user: user,
    board: board
  } do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Searchable Article Title",
          body: "body",
          slug: "searchable-art",
          user_id: user.id
        },
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

  test "board search by name shows results", %{conn: conn} do
    %Board{}
    |> Board.changeset(%{
      name: "Elixir Forum",
      slug: "elixir-forum-search",
      min_role_to_view: "guest"
    })
    |> Repo.insert!()

    {:ok, _lv, html} = live(conn, "/search?q=Elixir+Forum&tab=boards")
    assert html =~ "Elixir Forum"
    assert html =~ ~s(href="/boards/elixir-forum-search")
  end

  test "board search by description shows results", %{conn: conn} do
    %Board{}
    |> Board.changeset(%{
      name: "General",
      slug: "general-desc-search",
      description: "A board for general programming discussion",
      min_role_to_view: "guest"
    })
    |> Repo.insert!()

    {:ok, _lv, html} = live(conn, "/search?q=programming+discussion&tab=boards")
    assert html =~ "General"
    assert html =~ "general programming discussion"
  end

  test "board search shows empty state", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/search?q=zzzznonexistent&tab=boards")
    assert html =~ "No boards found"
  end

  test "board search respects visibility", %{conn: conn} do
    %Board{}
    |> Board.changeset(%{
      name: "Admin Secret Board",
      slug: "admin-secret-search",
      min_role_to_view: "admin"
    })
    |> Repo.insert!()

    {:ok, _lv, html} = live(conn, "/search?q=Secret+Board&tab=boards")
    refute html =~ "Admin Secret Board"
    assert html =~ "No boards found"
  end

  test "operator search shows filtered results", %{conn: conn, user: user, board: board} do
    {:ok, _} =
      Content.create_article(
        %{
          title: "Operator Target",
          body: "test content",
          slug: "op-target-lv",
          user_id: user.id
        },
        [board.id]
      )

    {:ok, _} =
      Content.create_article(
        %{
          title: "Other Article",
          body: "different content",
          slug: "op-other-lv",
          user_id: user.id
        },
        [board.id]
      )

    {:ok, _lv, html} = live(conn, "/search?q=board:public-search+Operator&tab=articles")
    assert html =~ "Operator Target"
  end

  test "operator help visible on articles tab", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/search?q=test&tab=articles")
    assert html =~ "Search operators"
    assert html =~ "author:username"
    assert html =~ "tag:tagname"
  end

  test "operator help not visible on other tabs", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/search?q=test&tab=comments")
    refute html =~ "Search operators"

    {:ok, _lv, html} = live(conn, "/search?q=test&tab=boards")
    refute html =~ "Search operators"

    {:ok, _lv, html} = live(conn, "/search?q=test&tab=users")
    refute html =~ "Search operators"
  end
end
