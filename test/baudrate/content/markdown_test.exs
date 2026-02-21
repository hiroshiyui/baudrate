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

    test "escapes script tags to prevent XSS" do
      html = Markdown.to_html("<script>alert('xss')</script>")
      refute html =~ "<script>"
      assert html =~ "&lt;script"
    end

    test "escapes img onerror injection" do
      html = Markdown.to_html(~S[<img src=x onerror="alert('xss')">])
      # The sanitizer preserves img but strips unsafe attributes
      refute html =~ "onerror"
    end

    test "escapes iframe injection" do
      html = Markdown.to_html(~S[<iframe src="https://evil.com"></iframe>])
      refute html =~ "<iframe"
      assert html =~ "&lt;iframe"
    end

    test "strips javascript: URIs from links" do
      html = Markdown.to_html(~S'[click](javascript:alert(1))')
      refute html =~ "javascript:"
    end
  end
end
