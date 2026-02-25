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
        %{
          title: "Article #{i}",
          body: "Body",
          slug: "pag-art-#{i}-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )
    end

    {:ok, _lv, html} = live(conn, "/boards/general")

    # Should show pagination
    assert html =~ "General"
    # DaisyUI join buttons
    assert html =~ "join-item"
  end

  test "updates article list when new article is created via PubSub", %{
    conn: conn,
    user: user,
    board: board
  } do
    {:ok, lv, html} = live(conn, "/boards/general")
    refute html =~ "PubSub Article"

    # Create an article from another process (simulates another user)
    Content.create_article(
      %{
        title: "PubSub Article",
        body: "body",
        slug: "pubsub-live-#{System.unique_integer([:positive])}",
        user_id: user.id
      },
      [board.id]
    )

    # The LiveView should re-render with the new article
    assert render(lv) =~ "PubSub Article"
  end

  test "board with children shows sub-board cards", %{conn: conn, board: board} do
    _child =
      %Board{}
      |> Board.changeset(%{name: "Sub Board", slug: "sub-board", parent_id: board.id})
      |> Repo.insert!()

    {:ok, _lv, html} = live(conn, "/boards/general")
    assert html =~ "Sub Board"
  end

  test "breadcrumb navigation on sub-board page", %{conn: conn, board: board} do
    child =
      %Board{}
      |> Board.changeset(%{name: "Child Board", slug: "child-board", parent_id: board.id})
      |> Repo.insert!()

    {:ok, _lv, html} = live(conn, "/boards/#{child.slug}")
    # Breadcrumb should contain parent board link
    assert html =~ "General"
    assert html =~ "Child Board"
  end

  test "shows comment count on articles", %{conn: conn, user: user, board: board} do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Commented Article",
          body: "Body",
          slug: "commented-art-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    other_user = setup_user("user")

    for _ <- 1..3 do
      Content.create_comment(%{
        "body" => "A comment",
        "article_id" => article.id,
        "user_id" => other_user.id
      })
    end

    {:ok, _lv, html} = live(conn, "/boards/general")
    assert html =~ "Commented Article"
    assert html =~ "hero-chat-bubble-left-ellipsis"
    assert html =~ "3"
  end

  test "navigates between pages", %{conn: conn, user: user, board: board} do
    for i <- 1..25 do
      Content.create_article(
        %{
          title: "Article #{i}",
          body: "Body",
          slug: "nav-art-#{i}-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )
    end

    {:ok, lv, _html} = live(conn, "/boards/general?page=2")

    # Should be on page 2
    assert render(lv) =~ "btn-active"
  end
end
