defmodule Baudrate.Content.LinkPreview.FetcherTest do
  use Baudrate.DataCase

  alias Baudrate.Content.LinkPreview
  alias Baudrate.Content.LinkPreview.Fetcher

  @og_html """
  <!DOCTYPE html>
  <html>
  <head>
    <meta property="og:title" content="Test Page" />
    <meta property="og:description" content="A test description" />
    <meta property="og:site_name" content="TestSite" />
    <meta property="og:image" content="https://example.com/image.jpg" />
    <title>Fallback Title</title>
  </head>
  <body><p>Hello</p></body>
  </html>
  """

  @twitter_html """
  <!DOCTYPE html>
  <html>
  <head>
    <meta name="twitter:title" content="Twitter Title" />
    <meta name="twitter:description" content="Twitter desc" />
    <title>Fallback Title</title>
  </head>
  <body></body>
  </html>
  """

  @minimal_html """
  <!DOCTYPE html>
  <html>
  <head>
    <title>Just a Title</title>
    <meta name="description" content="Meta description" />
  </head>
  <body></body>
  </html>
  """

  setup do
    # Stub rate limiter to allow all
    BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})

    # Stub HTTPClient via Req.Test
    Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
      Req.Test.html(conn, @og_html)
    end)

    :ok
  end

  describe "fetch_or_get/2" do
    test "fetches and stores OG metadata" do
      assert {:ok, %LinkPreview{} = preview} =
               Fetcher.fetch_or_get("https://example.com/test-page")

      assert preview.title == "Test Page"
      assert preview.description == "A test description"
      assert preview.site_name == "TestSite"
      assert preview.domain == "example.com"
      assert preview.status == "fetched"
      assert preview.fetched_at
    end

    test "returns cached preview on second call" do
      {:ok, first} = Fetcher.fetch_or_get("https://example.com/cached")
      {:ok, second} = Fetcher.fetch_or_get("https://example.com/cached")
      assert first.id == second.id
    end

    test "sanitizes HTML in metadata" do
      html = """
      <html><head>
        <meta property="og:title" content="Title &lt;script&gt;alert(1)&lt;/script&gt;" />
      </head><body></body></html>
      """

      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        Req.Test.html(conn, html)
      end)

      {:ok, preview} = Fetcher.fetch_or_get("https://example.com/xss-test")
      refute String.contains?(preview.title || "", "<script>")
    end

    test "truncates long titles" do
      long_title = String.duplicate("a", 500)

      html = """
      <html><head>
        <meta property="og:title" content="#{long_title}" />
      </head><body></body></html>
      """

      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        Req.Test.html(conn, html)
      end)

      {:ok, preview} = Fetcher.fetch_or_get("https://example.com/long-title")
      assert String.length(preview.title) <= 300
    end

    test "falls back to twitter card metadata" do
      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        Req.Test.html(conn, @twitter_html)
      end)

      {:ok, preview} = Fetcher.fetch_or_get("https://example.com/twitter-test")
      assert preview.title == "Twitter Title"
      assert preview.description == "Twitter desc"
    end

    test "falls back to title tag and meta description" do
      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        Req.Test.html(conn, @minimal_html)
      end)

      {:ok, preview} = Fetcher.fetch_or_get("https://example.com/minimal-test")
      assert preview.title == "Just a Title"
      assert preview.description == "Meta description"
    end
  end
end
