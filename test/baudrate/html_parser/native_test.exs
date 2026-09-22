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

    test "a host that only begins like ours is external" do
      # This was a string-prefix check, so `https://localhost.evil.example`
      # counted as the site's own.
      html = ~s(<a href="https://localhost.evil.example/x">x</a>)

      assert HtmlParser.extract_first_url(html, "https://localhost") ==
               "https://localhost.evil.example/x"
    end

    test "returns a link as written when it is already absolute" do
      html = ~s(<a href="https://例え.jp/パス">x</a>)
      assert HtmlParser.extract_first_url(html, "https://localhost") == "https://例え.jp/パス"
    end

    test "resolves a link that is not" do
      html = ~s(<a href="//example.com/page">x</a>)
      assert HtmlParser.extract_first_url(html, "https://localhost") == "https://example.com/page"
    end
  end

  describe "extract_urls/2" do
    @origin "https://localhost"

    defp urls(hrefs) do
      hrefs
      |> Enum.map_join(" ", &~s(<a href="#{&1}">x</a>))
      |> HtmlParser.extract_urls(@origin)
    end

    test "every external link, in document order" do
      assert urls(["https://a.example/1", "https://b.example/2"]) ==
               ["https://a.example/1", "https://b.example/2"]
    end

    test "resolves each link the way a browser does" do
      # All of these leave the site. A count that looked for an `https://`
      # prefix would have found none of them.
      assert urls(["//a.example/x"]) == ["https://a.example/x"]
      assert urls(["/\\b.example/x"]) == ["https://b.example/x"]
      assert urls(["\\\\c.example/x"]) == ["https://c.example/x"]
      assert urls(["http:d.example"]) == ["http://d.example/"]
      assert urls(["ht\ntps://e.example/"]) == ["https://e.example/"]
    end

    test "links on this host do not count, whatever their form" do
      assert urls(["/boards/x", "https://LOCALHOST/y", "https:relative", "?q=1", "#top"]) == []
    end

    test "userinfo does not make a link local" do
      assert urls(["https://localhost@evil.example/"]) == ["https://localhost@evil.example/"]
    end

    test "the same page twice is one URL, fragments aside" do
      assert urls(["https://a.example", "https://a.example/", "https://a.example/#part"]) ==
               ["https://a.example/"]
    end

    test "skips non-web schemes and classed tag and mention links" do
      html = """
      <a href="mailto:x@example.com">m</a>
      <a href="https://remote.example/tags/t" class="hashtag">#t</a>
      <a href="https://remote.example/@u" class="u-url mention">@u</a>
      """

      assert HtmlParser.extract_urls(html, @origin) == []
    end

    test "an origin that does not parse yields nothing rather than everything" do
      assert HtmlParser.extract_urls(~s(<a href="https://a.example/">x</a>), "not a url") == []
    end
  end

  describe "count_images/1" do
    test "counts every image element" do
      assert HtmlParser.count_images(~s(<p><img src="/media/a"> and <img src="/media/b"></p>)) ==
               2
    end

    test "zero when there are none" do
      assert HtmlParser.count_images("<p>&lt;img src=x&gt;</p>") == 0
      assert HtmlParser.count_images("") == 0
    end
  end
end
