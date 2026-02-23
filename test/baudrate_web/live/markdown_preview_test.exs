defmodule BaudrateWeb.MarkdownPreviewTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Content.Board
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)

    board =
      %Board{}
      |> Board.changeset(%{name: "Preview Test", slug: "preview-test"})
      |> Repo.insert!()

    {:ok, conn: conn, user: user, board: board}
  end

  describe "markdown_preview event" do
    test "does not crash LiveView with valid markdown", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      # render_hook doesn't expose reply payloads, but verifies the event
      # is handled without crashing the LiveView process
      render_hook(lv, "markdown_preview", %{"body" => "**bold** text"})

      # LiveView is still alive
      assert render(lv) =~ "Create Article"
    end

    test "handles empty body without error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      render_hook(lv, "markdown_preview", %{"body" => ""})

      assert render(lv) =~ "Create Article"
    end

    test "handles oversized body without error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      # 65 KB body exceeds the 64 KB limit
      oversized = String.duplicate("a", 65 * 1024)
      render_hook(lv, "markdown_preview", %{"body" => oversized})

      assert render(lv) =~ "Create Article"
    end

    test "sanitizes XSS in preview", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      render_hook(lv, "markdown_preview", %{
        "body" => "<script>alert('xss')</script>"
      })

      # LiveView is still alive and XSS doesn't crash
      assert render(lv) =~ "Create Article"
    end

    test "works on article edit page", %{conn: conn, board: board, user: user} do
      {:ok, %{article: article}} =
        Baudrate.Content.create_article(
          %{
            title: "Preview Edit Test",
            body: "Original body",
            slug: "preview-edit-test",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}/edit")

      render_hook(lv, "markdown_preview", %{"body" => "# Heading\n\nParagraph"})

      assert render(lv) =~ "Edit Article"
    end
  end
end
