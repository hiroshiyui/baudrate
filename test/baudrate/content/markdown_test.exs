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

  describe "hashtag linkification" do
    test "linkifies #tag to clickable link" do
      html = Markdown.to_html("Check out #elixir")
      assert html =~ ~s[<a href="/tags/elixir" class="hashtag">#elixir</a>]
    end

    test "does not linkify tags inside code blocks" do
      html = Markdown.to_html("`#not_a_tag`")
      refute html =~ "hashtag"
      assert html =~ "#not_a_tag"
    end

    test "does not linkify tags inside fenced code blocks" do
      html = Markdown.to_html("```\n#not_a_tag\n```")
      refute html =~ ~s[class="hashtag"]
    end

    test "does not linkify tags inside links" do
      html = Markdown.to_html("[#elixir](https://example.com)")
      # The tag inside an existing link should not get double-linked
      refute html =~ ~s[class="hashtag"]
    end

    test "handles multiple tags in one text" do
      html = Markdown.to_html("Learn #elixir and #phoenix today")
      assert html =~ ~s[<a href="/tags/elixir" class="hashtag">#elixir</a>]
      assert html =~ ~s[<a href="/tags/phoenix" class="hashtag">#phoenix</a>]
    end

    test "does not linkify markdown headings (# Heading)" do
      html = Markdown.to_html("# Heading")
      assert html =~ "<h1>"
      refute html =~ ~s[class="hashtag"]
    end

    test "linkifies CJK hashtags correctly" do
      html = Markdown.to_html("Visit #台灣 and learn #エリクサー")
      assert html =~ ~s[<a href="/tags/台灣" class="hashtag">#台灣</a>]
      assert html =~ ~s[<a href="/tags/エリクサー" class="hashtag">#エリクサー</a>]
    end

    test "normalizes tag links to lowercase" do
      html = Markdown.to_html("Check #Elixir")
      assert html =~ ~s[href="/tags/elixir"]
      # The display text preserves original case
      assert html =~ "#Elixir</a>"
    end
  end

  describe "extract_mentions/1" do
    test "extracts a single mention" do
      assert Markdown.extract_mentions("Hello @alice") == ["alice"]
    end

    test "extracts multiple mentions" do
      assert Markdown.extract_mentions("@alice and @bob are here") == ["alice", "bob"]
    end

    test "returns unique downcased usernames" do
      assert Markdown.extract_mentions("@Alice and @alice again") == ["alice"]
    end

    test "returns empty list for nil" do
      assert Markdown.extract_mentions(nil) == []
    end

    test "returns empty list for empty string" do
      assert Markdown.extract_mentions("") == []
    end

    test "does not match inside inline code" do
      assert Markdown.extract_mentions("Use `@config` here") == []
    end

    test "does not match inside fenced code blocks" do
      text = "```\n@username\n```"
      assert Markdown.extract_mentions(text) == []
    end

    test "does not match email-like patterns" do
      assert Markdown.extract_mentions("send to foo@bar") == []
    end

    test "rejects usernames shorter than 3 chars" do
      assert Markdown.extract_mentions("@ab is too short") == []
    end

    test "rejects usernames longer than 32 chars" do
      long_name = String.duplicate("a", 33)
      assert Markdown.extract_mentions("@#{long_name}") == []
    end

    test "accepts usernames with underscores and numbers" do
      assert Markdown.extract_mentions("@user_123") == ["user_123"]
    end

    test "extracts mention at start of text" do
      assert Markdown.extract_mentions("@alice hello") == ["alice"]
    end

    test "extracts mention at end of text" do
      assert Markdown.extract_mentions("hello @alice") == ["alice"]
    end
  end

  describe "mention linkification" do
    test "linkifies @username to profile link" do
      html = Markdown.to_html("Hello @alice")
      assert html =~ ~s[<a href="/users/alice" class="mention">@alice</a>]
    end

    test "preserves original case in display" do
      html = Markdown.to_html("Hello @Alice")
      assert html =~ ~s[<a href="/users/alice" class="mention">@Alice</a>]
    end

    test "does not linkify mentions inside code" do
      html = Markdown.to_html("`@alice`")
      refute html =~ "mention"
      assert html =~ "@alice"
    end

    test "does not linkify mentions inside pre blocks" do
      html = Markdown.to_html("```\n@alice\n```")
      refute html =~ ~s[class="mention"]
    end

    test "does not linkify mentions inside links" do
      html = Markdown.to_html("[@alice](https://example.com)")
      refute html =~ ~s[class="mention"]
    end

    test "handles multiple mentions in one text" do
      html = Markdown.to_html("@alice and @bob")
      assert html =~ ~s[<a href="/users/alice" class="mention">@alice</a>]
      assert html =~ ~s[<a href="/users/bob" class="mention">@bob</a>]
    end

    test "linkifies both hashtags and mentions" do
      html = Markdown.to_html("@alice posted about #elixir")
      assert html =~ ~s[class="mention"]
      assert html =~ ~s[class="hashtag"]
    end
  end
end
