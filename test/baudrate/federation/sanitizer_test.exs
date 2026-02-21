defmodule Baudrate.Federation.SanitizerTest do
  use ExUnit.Case, async: true

  alias Baudrate.Federation.Sanitizer

  describe "sanitize/1" do
    test "preserves safe tags: p, br, strong, em" do
      html = "<p>Hello <strong>world</strong> <em>italic</em></p><br>"
      result = Sanitizer.sanitize(html)
      assert result =~ "<p>"
      assert result =~ "<strong>"
      assert result =~ "<em>"
      assert result =~ "<br>"
    end

    test "preserves safe tags: a, code, pre, blockquote" do
      html =
        "<a href=\"https://example.com\">link</a><code>code</code><pre>pre</pre><blockquote>quote</blockquote>"

      result = Sanitizer.sanitize(html)
      assert result =~ "<a "
      assert result =~ "<code>"
      assert result =~ "<pre>"
      assert result =~ "<blockquote>"
    end

    test "preserves safe tags: ul, ol, li" do
      html = "<ul><li>one</li></ul><ol><li>two</li></ol>"
      result = Sanitizer.sanitize(html)
      assert result =~ "<ul>"
      assert result =~ "<ol>"
      assert result =~ "<li>"
    end

    test "preserves heading tags h1-h6" do
      for n <- 1..6 do
        html = "<h#{n}>heading</h#{n}>"
        result = Sanitizer.sanitize(html)
        assert result =~ "<h#{n}>", "Expected h#{n} to be preserved"
      end
    end

    test "strips script tags with content" do
      html = "<p>Hello</p><script>alert('xss')</script><p>World</p>"
      result = Sanitizer.sanitize(html)
      refute result =~ "script"
      refute result =~ "alert"
      assert result =~ "<p>"
    end

    test "strips style tags with content" do
      html = "<p>Hello</p><style>body { display: none; }</style><p>World</p>"
      result = Sanitizer.sanitize(html)
      refute result =~ "style"
      refute result =~ "display"
    end

    test "strips iframe tags" do
      html = "<p>Before</p><iframe src=\"https://evil.example\"></iframe><p>After</p>"
      result = Sanitizer.sanitize(html)
      refute result =~ "iframe"
    end

    test "strips object tags" do
      html = "<p>Before</p><object data=\"evil.swf\"></object><p>After</p>"
      result = Sanitizer.sanitize(html)
      refute result =~ "object"
    end

    test "strips embed tags" do
      html = "<p>Before</p><embed src=\"evil.swf\"></embed><p>After</p>"
      result = Sanitizer.sanitize(html)
      refute result =~ "embed"
    end

    test "strips form, input, textarea tags" do
      html = "<form action=\"/steal\"><input type=\"text\"><textarea>data</textarea></form>"
      result = Sanitizer.sanitize(html)
      refute result =~ "form"
      refute result =~ "input"
      refute result =~ "textarea"
    end

    test "strips event handlers: onclick" do
      html = "<p onclick=\"alert('xss')\">click me</p>"
      result = Sanitizer.sanitize(html)
      refute result =~ "onclick"
      refute result =~ "alert"
    end

    test "strips event handlers: onmouseover" do
      html = "<p onmouseover=\"alert('xss')\">hover me</p>"
      result = Sanitizer.sanitize(html)
      refute result =~ "onmouseover"
    end

    test "strips event handlers: onerror" do
      html = "<img onerror=\"alert('xss')\" src=\"x\">"
      result = Sanitizer.sanitize(html)
      refute result =~ "onerror"
    end

    test "sanitizes a href: allows http and https" do
      html = "<a href=\"https://example.com\">link1</a><a href=\"http://example.com\">link2</a>"
      result = Sanitizer.sanitize(html)
      assert result =~ "example.com"
    end

    test "sanitizes a href: rejects javascript: scheme" do
      html = "<a href=\"javascript:alert('xss')\">click</a>"
      result = Sanitizer.sanitize(html)
      refute result =~ "javascript"
    end

    test "adds rel nofollow noopener noreferrer to links" do
      html = "<a href=\"https://example.com\">link</a>"
      result = Sanitizer.sanitize(html)
      assert result =~ "rel=\"nofollow noopener noreferrer\""
    end

    test "handles nil input" do
      assert "" = Sanitizer.sanitize(nil)
    end

    test "handles empty string input" do
      assert "" = Sanitizer.sanitize("")
    end

    test "strips HTML comments" do
      html = "<p>Hello</p><!-- secret comment --><p>World</p>"
      result = Sanitizer.sanitize(html)
      refute result =~ "<!--"
      refute result =~ "secret"
      assert result =~ "<p>"
    end

    test "strips unknown/unsafe tags while preserving text" do
      html = "<div>content in div</div>"
      result = Sanitizer.sanitize(html)
      refute result =~ "<div>"
      assert result =~ "content in div"
    end

    test "preserves span with h-card class (Mastodon mentions)" do
      html = ~s(<span class="h-card"><a href="https://example.com/@alice">@alice</a></span>)
      result = Sanitizer.sanitize(html)
      assert result =~ ~s(<span class="h-card">)
      assert result =~ "<a "
    end

    test "preserves span with hashtag class (Mastodon hashtags)" do
      html = ~s(<span class="hashtag">#elixir</span>)
      result = Sanitizer.sanitize(html)
      assert result =~ ~s(<span class="hashtag">)
    end

    test "preserves span with mention class" do
      html = ~s(<span class="mention">@bob</span>)
      result = Sanitizer.sanitize(html)
      assert result =~ ~s(<span class="mention">)
    end

    test "preserves span with invisible class" do
      html = ~s(<span class="invisible">hidden</span>)
      result = Sanitizer.sanitize(html)
      assert result =~ ~s(<span class="invisible">)
    end

    test "strips unsafe class from span" do
      html = ~s(<span class="malicious-class">text</span>)
      result = Sanitizer.sanitize(html)
      assert result =~ "<span>"
      refute result =~ "malicious-class"
    end

    test "span without class has attributes stripped" do
      html = ~s(<span style="color:red">text</span>)
      result = Sanitizer.sanitize(html)
      assert result =~ "<span>"
      refute result =~ "style"
    end

    test "span with mixed safe and unsafe classes keeps only safe" do
      html = ~s(<span class="h-card evil-class mention">text</span>)
      result = Sanitizer.sanitize(html)
      assert result =~ "h-card"
      assert result =~ "mention"
      refute result =~ "evil-class"
    end
  end
end
