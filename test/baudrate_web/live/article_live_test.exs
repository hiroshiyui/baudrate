defmodule BaudrateWeb.ArticleLiveTest do
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
      |> Board.changeset(%{name: "General", slug: "general-art"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Test Article", body: "Article body text", slug: "test-article", user_id: user.id},
        [board.id]
      )

    {:ok, conn: conn, user: user, board: board, article: article}
  end

  test "renders article with edit/delete buttons for author", %{conn: conn, article: article} do
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Test Article"
    assert html =~ "Edit"
    assert html =~ "Delete"
  end

  test "does not show edit/delete for non-author", %{article: article} do
    Repo.insert!(%Setting{key: "registration_mode", value: "open"})
    other_user = setup_user("user")

    conn =
      Phoenix.ConnTest.build_conn()
      |> log_in_user(other_user)

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Test Article"
    refute html =~ "hero-pencil-square"
  end

  test "deletes article and redirects", %{conn: conn, article: article} do
    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

    lv |> element("button[phx-click=delete_article]") |> render_click()

    assert_redirect(lv)
  end

  test "renders comment section", %{conn: conn, article: article} do
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Comments"
    assert html =~ "Write a comment"
  end

  test "posts a comment", %{conn: conn, article: article} do
    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

    html =
      lv
      |> form("form[phx-submit=submit_comment]", comment: %{body: "Great article!"})
      |> render_submit()

    assert html =~ "Great article!"
  end

  test "updates comment list when new comment is posted via PubSub", %{conn: conn, user: user, article: article} do
    {:ok, lv, html} = live(conn, "/articles/#{article.slug}")
    refute html =~ "PubSub comment here"

    # Create a comment from another process (simulates another user)
    Content.create_comment(%{
      "body" => "PubSub comment here",
      "article_id" => article.id,
      "user_id" => user.id
    })

    # The LiveView should re-render with the new comment
    assert render(lv) =~ "PubSub comment here"
  end

  test "updates comment list when comment is deleted via PubSub", %{conn: conn, user: user, article: article} do
    {:ok, comment} =
      Content.create_comment(%{
        "body" => "Will be deleted remotely",
        "article_id" => article.id,
        "user_id" => user.id
      })

    {:ok, lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Will be deleted remotely"

    # Delete the comment from another process
    Content.soft_delete_comment(comment)

    # The LiveView should re-render without the deleted comment
    refute render(lv) =~ "Will be deleted remotely"
  end

  test "displays author signature after article body", %{conn: conn, user: user, article: article} do
    {:ok, _updated_user} = Baudrate.Auth.update_signature(user, "My **awesome** signature")

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Signature"
    assert html =~ "awesome"
  end

  test "comment pagination controls appear when root comments exceed per_page", %{conn: conn, user: user, article: article} do
    # Create 21 root comments (exceeds default per_page of 20)
    for i <- 1..21 do
      Content.create_comment(%{
        "body" => "Root comment #{i}",
        "article_id" => article.id,
        "user_id" => user.id
      })
    end

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    # Pagination should render with next-page button
    assert html =~ "join-item btn btn-sm btn-active"
    assert html =~ "»"
  end

  test "threaded replies stay with their root when paginated", %{conn: conn, user: user, article: article} do
    # Create 21 root comments so we have 2 pages
    root_comments =
      for i <- 1..21 do
        {:ok, c} =
          Content.create_comment(%{
            "body" => "Root #{i}",
            "article_id" => article.id,
            "user_id" => user.id
          })

        c
      end

    # Add a reply to the first root comment
    first_root = List.first(root_comments)

    {:ok, _reply} =
      Content.create_comment(%{
        "body" => "Reply to first root",
        "article_id" => article.id,
        "user_id" => user.id,
        "parent_id" => first_root.id
      })

    # Page 1 should show the first root and its reply
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Root 1"
    assert html =~ "Reply to first root"
  end
end
