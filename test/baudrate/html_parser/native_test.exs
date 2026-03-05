defmodule Baudrate.HtmlParser.NativeTest do
  use ExUnit.Case, async: true

  alias Baudrate.HtmlParser.Native, as: HtmlParser

  describe "parse_og_metadata/1" do
    test "extracts OG metadata" do
      html = """
      <html><head>
        <meta property="og:title" content="Test Title">
        <meta property="og:description" content="Test Description">
        <meta property="og:image" content="https://example.com/image.jpg">
        <meta property="og:site_name" content="Example">
      </head><body></body></html>
      """

      result = HtmlParser.parse_og_metadata(html)
      assert result.title == "Test Title"
      assert result.description == "Test Description"
      assert result.image_url == "https://example.com/image.jpg"
      assert result.site_name == "Example"
    end

    test "falls back to Twitter Card metadata" do
      html = """
      <html><head>
        <meta name="twitter:title" content="Twitter Title">
        <meta name="twitter:description" content="Twitter Desc">
        <meta name="twitter:image" content="https://example.com/tw.jpg">
      </head><body></body></html>
      """

      result = HtmlParser.parse_og_metadata(html)
      assert result.title == "Twitter Title"
      assert result.description == "Twitter Desc"
      assert result.image_url == "https://example.com/tw.jpg"
    end

    test "falls back to <title> tag and meta description" do
      html = """
      <html><head>
        <title>Page Title</title>
        <meta name="description" content="Meta desc">
      </head><body></body></html>
      """

      result = HtmlParser.parse_og_metadata(html)
      assert result.title == "Page Title"
      assert result.description == "Meta desc"
      assert result.image_url == nil
      assert result.site_name == nil
    end

    test "OG takes priority over Twitter Card and fallbacks" do
      html = """
      <html><head>
        <title>Fallback Title</title>
        <meta name="twitter:title" content="Twitter Title">
        <meta property="og:title" content="OG Title">
      </head><body></body></html>
      """

      result = HtmlParser.parse_og_metadata(html)
      assert result.title == "OG Title"
    end

    test "returns nil fields for empty HTML" do
      result = HtmlParser.parse_og_metadata("")
      assert result.title == nil
      assert result.description == nil
      assert result.image_url == nil
      assert result.site_name == nil
    end
  end

  describe "extract_first_url/2" do
    test "extracts first external URL" do
      html = ~s(<a href="https://example.com/page">Link</a>)
      assert HtmlParser.extract_first_url(html, "https://localhost") == "https://example.com/page"
    end

    test "skips same-origin URLs" do
      html = """
      <a href="https://localhost/local">Local</a>
      <a href="https://example.com/ext">External</a>
      """

      assert HtmlParser.extract_first_url(html, "https://localhost") ==
               "https://example.com/ext"
    end

    test "skips hashtag links" do
      html = """
      <a href="https://remote.example/tags/test" class="hashtag">#test</a>
      <a href="https://example.com/page">Real link</a>
      """

      assert HtmlParser.extract_first_url(html, "https://localhost") ==
               "https://example.com/page"
    end

    test "skips mention links" do
      html = """
      <a href="https://remote.example/@user" class="u-url mention">@user</a>
      <a href="https://example.com/page">Real link</a>
      """

      assert HtmlParser.extract_first_url(html, "https://localhost") ==
               "https://example.com/page"
    end

    test "skips fragment-only links" do
      html = """
      <a href="#section">Section</a>
      <a href="https://example.com/page">Real link</a>
      """

      assert HtmlParser.extract_first_url(html, "https://localhost") ==
               "https://example.com/page"
    end

    test "skips non-HTTP(S) URLs" do
      html = """
      <a href="mailto:user@example.com">Email</a>
      <a href="https://example.com/page">Real link</a>
      """

      assert HtmlParser.extract_first_url(html, "https://localhost") ==
               "https://example.com/page"
    end

    test "returns nil when no external URL found" do
      html = ~s(<a href="https://localhost/local">Local only</a>)
      assert HtmlParser.extract_first_url(html, "https://localhost") == nil
    end

    test "returns nil for empty HTML" do
      assert HtmlParser.extract_first_url("", "https://localhost") == nil
    end
  end
end
