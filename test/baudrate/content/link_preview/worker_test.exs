defmodule Baudrate.Content.LinkPreview.WorkerTest do
  use Baudrate.DataCase

  import BaudrateWeb.ConnCase, only: [setup_user: 1]

  alias Baudrate.Content
  alias Baudrate.Content.LinkPreview.Worker

  @og_html """
  <!DOCTYPE html>
  <html>
  <head>
    <meta property="og:title" content="Worker Test" />
    <meta property="og:description" content="Testing the worker" />
  </head>
  <body></body>
  </html>
  """

  setup do
    BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})

    Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
      Req.Test.html(conn, @og_html)
    end)

    :ok
  end

  describe "schedule_preview_fetch/4" do
    test "attaches failed preview record to article when fetch fails" do
      # Simulates what happens with large pages (e.g. YouTube) that exceed
      # the 256 KB max_payload_size: fetch fails but the failed record must
      # still be linked so embed fallbacks can render.
      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 403, "Forbidden")
      end)

      user = setup_user("user")
      board = create_test_board()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Failed Preview",
            "body" => "Check https://example.com/blocked-page",
            "slug" => "failed-preview-attach",
            "user_id" => user.id
          },
          [board.id]
        )

      body_html = Baudrate.Content.Markdown.to_html(article.body)
      Worker.schedule_preview_fetch(:article, article.id, body_html, user.id)

      updated = Content.get_article_by_slug!("failed-preview-attach")
      assert updated.link_preview_id, "expected failed preview to be attached"
      assert updated.link_preview.status == "failed"
      assert updated.link_preview.url == "https://example.com/blocked-page"
    end

    test "attaches failed preview for YouTube URL so embed can render" do
      # YouTube HTML pages are ~500 KB–1 MB and exceed max_payload_size (256 KB).
      # The worker must still attach the failed record; the component derives
      # the video ID from the stored URL without needing a successful fetch.
      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        big_body = String.duplicate("x", 256 * 1024 + 1)

        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, big_body)
      end)

      user = setup_user("user")
      board = create_test_board()

      youtube_url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "YouTube Article",
            "body" => "Watch this: #{youtube_url}",
            "slug" => "youtube-embed-test",
            "user_id" => user.id
          },
          [board.id]
        )

      body_html = Baudrate.Content.Markdown.to_html(article.body)
      Worker.schedule_preview_fetch(:article, article.id, body_html, user.id)

      updated = Content.get_article_by_slug!("youtube-embed-test")
      assert updated.link_preview_id, "expected failed YouTube preview to be attached"
      assert updated.link_preview.status == "failed"
      assert updated.link_preview.url == youtube_url
    end

    test "fetches preview and attaches to article" do
      user = setup_user("user")
      board = create_test_board()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Test Article",
            "body" => "Check out https://example.com/worker-test for more info",
            "slug" => "test-link-preview",
            "user_id" => user.id
          },
          [board.id]
        )

      body_html = Baudrate.Content.Markdown.to_html(article.body)

      Worker.schedule_preview_fetch(:article, article.id, body_html, user.id)

      # Re-fetch the article to check link_preview_id
      updated = Content.get_article_by_slug!("test-link-preview")
      assert updated.link_preview_id
      assert updated.link_preview.title == "Worker Test"
    end

    test "does nothing when no external URLs in content" do
      user = setup_user("user")
      board = create_test_board()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "No Links",
            "body" => "Just some text without links",
            "slug" => "no-links-preview",
            "user_id" => user.id
          },
          [board.id]
        )

      body_html = Baudrate.Content.Markdown.to_html(article.body)

      Worker.schedule_preview_fetch(:article, article.id, body_html, user.id)

      updated = Content.get_article_by_slug!("no-links-preview")
      refute updated.link_preview_id
    end
  end

  defp create_test_board do
    {:ok, board} =
      Content.create_board(%{
        name: "Test Board #{System.unique_integer([:positive])}",
        slug: "test-lp-board-#{System.unique_integer([:positive])}",
        description: "Test board for link preview tests"
      })

    board
  end
end
