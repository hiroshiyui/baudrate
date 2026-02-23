defmodule Baudrate.Content.MarkdownTest do
  use ExUnit.Case, async: true

  alias Baudrate.Content.Markdown

  describe "to_html/1" do
    test "renders basic markdown to HTML" do
      assert Markdown.to_html("**bold**") =~ "<strong>bold</strong>"
    end

    test "renders headings" do
      assert Markdown.to_html("# Hello") =~ "<h1>"
    end

    test "renders links with safe attributes" do
      html = Markdown.to_html("[link](https://example.com)")
      assert html =~ ~s(href="https://example.com")
      assert html =~ ~s(rel="nofollow noopener")
    end

    test "renders code blocks" do
      html = Markdown.to_html("```\ncode\n```")
      assert html =~ "<code"
    end

    test "returns empty string for nil" do
      assert Markdown.to_html(nil) == ""
    end

    test "returns empty string for empty string" do
      assert Markdown.to_html("") == ""
    end

    test "strips script tags and content to prevent XSS" do
      html = Markdown.to_html("<script>alert('xss')</script>")
      refute html =~ "<script>"
      refute html =~ "alert"
    end

    test "escapes img onerror injection" do
      html = Markdown.to_html(~S[<img src=x onerror="alert('xss')">])
      # The sanitizer preserves img but strips unsafe attributes
      refute html =~ "onerror"
    end

    test "strips iframe injection" do
      html = Markdown.to_html(~S[<iframe src="https://evil.com"></iframe>])
      refute html =~ "<iframe"
      refute html =~ "iframe"
    end

    test "strips javascript: URIs from links" do
      html = Markdown.to_html(~S'[click](javascript:alert(1))')
      refute html =~ "javascript:"
    end

    test "strips nested/malformed script tags completely" do
      html = Markdown.to_html("<script>a<script>b</script>c</script>")
      refute html =~ "script"
    end

    test "strips unclosed script tags" do
      html = Markdown.to_html("<script>payload")
      refute html =~ "script"
      refute html =~ "payload"
    end

    test "strips onclick from allowed tags via parser" do
      html = Markdown.to_html("<a href=\"https://ok.example\" onclick=\"evil()\">link</a>")
      refute html =~ "onclick"
      refute html =~ "evil"
    end

    test "strips svg with onload event handler" do
      html = Markdown.to_html(~s[<svg onload="alert(1)">content</svg>])
      refute html =~ "svg"
      refute html =~ "onload"
      refute html =~ "alert"
    end

    test "strips svg with embedded script" do
      html = Markdown.to_html("<svg><script>alert(1)</script></svg>")
      refute html =~ "svg"
      refute html =~ "script"
      refute html =~ "alert"
    end

    test "strips math tags" do
      html = Markdown.to_html(~s[<math><mi>x</mi></math>])
      refute html =~ "math"
    end

    test "rejects data: URI scheme on links" do
      scheme = "data"
      html = Markdown.to_html(~s[<a href="#{scheme}:text/html,payload">click</a>])
      refute html =~ scheme <> ":"
    end
  end
end
