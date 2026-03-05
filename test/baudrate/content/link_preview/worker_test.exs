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
