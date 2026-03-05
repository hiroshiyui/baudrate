defmodule Baudrate.Content.LinkPreview.UrlExtractorTest do
  use Baudrate.DataCase

  alias Baudrate.Content.LinkPreview.UrlExtractor

  describe "extract_first_url/1" do
    test "extracts the first external HTTP URL" do
      html =
        ~s(<p>Check out <a href="https://example.com/page">this page</a> and <a href="https://other.com">other</a></p>)

      assert {:ok, "https://example.com/page"} = UrlExtractor.extract_first_url(html)
    end

    test "skips same-origin URLs" do
      origin = BaudrateWeb.Endpoint.url()

      html =
        ~s(<p><a href="#{origin}/articles/test">local</a> <a href="https://external.com">ext</a></p>)

      assert {:ok, "https://external.com"} = UrlExtractor.extract_first_url(html)
    end

    test "skips hashtag links" do
      html =
        ~s(<p><a href="https://example.com/tags/test" class="hashtag">#test</a> <a href="https://real.com">real</a></p>)

      assert {:ok, "https://real.com"} = UrlExtractor.extract_first_url(html)
    end

    test "skips mention links" do
      html =
        ~s(<p><a href="https://example.com/@user" class="mention">@user</a> <a href="https://real.com">real</a></p>)

      assert {:ok, "https://real.com"} = UrlExtractor.extract_first_url(html)
    end

    test "skips fragment-only links" do
      html = ~s(<p><a href="#section">jump</a> <a href="https://real.com">real</a></p>)

      assert {:ok, "https://real.com"} = UrlExtractor.extract_first_url(html)
    end

    test "skips non-HTTP schemes" do
      html =
        ~s(<p><a href="mailto:test@example.com">email</a> <a href="https://real.com">real</a></p>)

      assert {:ok, "https://real.com"} = UrlExtractor.extract_first_url(html)
    end

    test "returns :none when no external URLs found" do
      html = ~s(<p>No links here</p>)
      assert :none = UrlExtractor.extract_first_url(html)
    end

    test "returns :none for empty string" do
      assert :none = UrlExtractor.extract_first_url("")
    end

    test "returns :none for nil" do
      assert :none = UrlExtractor.extract_first_url(nil)
    end

    test "handles HTTP URLs" do
      html = ~s(<p><a href="http://example.com/page">link</a></p>)
      assert {:ok, "http://example.com/page"} = UrlExtractor.extract_first_url(html)
    end

    test "returns only the first URL when multiple exist" do
      html = ~s(<p><a href="https://first.com">1</a> <a href="https://second.com">2</a></p>)
      assert {:ok, "https://first.com"} = UrlExtractor.extract_first_url(html)
    end
  end
end
