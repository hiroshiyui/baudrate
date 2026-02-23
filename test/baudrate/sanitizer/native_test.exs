defmodule Baudrate.Sanitizer.NativeTest do
  use ExUnit.Case, async: true

  alias Baudrate.Sanitizer.Native

  # --- sanitize_federation/1 ---

  describe "sanitize_federation/1" do
    test "preserves allowed inline tags: p, br, hr, em, strong, del" do
      html = "<p>Hello <strong>bold</strong> <em>italic</em> <del>struck</del></p><br><hr>"
      result = Native.sanitize_federation(html)
      assert result =~ "<p>"
      assert result =~ "<strong>"
      assert result =~ "<em>"
      assert result =~ "<del>"
      assert result =~ "<br"
      assert result =~ "<hr"
    end

    test "preserves code, pre, blockquote" do
      html = "<code>x</code><pre>y</pre><blockquote>z</blockquote>"
      result = Native.sanitize_federation(html)
      assert result =~ "<code>"
      assert result =~ "<pre>"
      assert result =~ "<blockquote>"
    end

    test "preserves list tags: ul, ol, li" do
      html = "<ul><li>a</li></ul><ol><li>b</li></ol>"
      result = Native.sanitize_federation(html)
      assert result =~ "<ul>"
      assert result =~ "<ol>"
      assert result =~ "<li>"
    end

    test "preserves heading tags h1-h6" do
      for n <- 1..6 do
        html = "<h#{n}>heading</h#{n}>"
        result = Native.sanitize_federation(html)
        assert result =~ "<h#{n}>", "Expected h#{n} to be preserved"
      end
    end

    test "preserves a[href] with http/https" do
      html =
        ~s[<a href="https://example.com">link1</a><a href="http://example.com">link2</a>]

      result = Native.sanitize_federation(html)
      assert result =~ "https://example.com"
      assert result =~ "http://example.com"
    end

    test "preserves span with safe classes: h-card, hashtag, mention, invisible" do
      for class <- ~w[h-card hashtag mention invisible] do
        html = ~s[<span class="#{class}">text</span>]
        result = Native.sanitize_federation(html)
        assert result =~ ~s[class="#{class}"], "Expected #{class} to be preserved"
      end
    end

    test "strips unsafe class from span but keeps tag" do
      html = ~s[<span class="malicious">text</span>]
      result = Native.sanitize_federation(html)
      assert result =~ "<span>"
      refute result =~ "malicious"
    end

    test "keeps only safe classes from mixed class list" do
      html = ~s[<span class="h-card evil mention">text</span>]
      result = Native.sanitize_federation(html)
      assert result =~ "h-card"
      assert result =~ "mention"
      refute result =~ "evil"
    end

    test "strips script tag and content" do
      html = "<p>ok</p><script>alert('xss')</script><p>fine</p>"
      result = Native.sanitize_federation(html)
      refute result =~ "script"
      refute result =~ "alert"
    end

    test "strips style tag and content" do
      html = "<p>ok</p><style>body{display:none}</style>"
      result = Native.sanitize_federation(html)
      refute result =~ "style"
      refute result =~ "display"
    end

    for tag <- ~w[iframe object embed form input textarea svg math] do
      test "strips #{tag} tag" do
        html = "<p>ok</p><#{unquote(tag)}>inside</#{unquote(tag)}>"
        result = Native.sanitize_federation(html)
        refute result =~ unquote(tag)
      end
    end

    test "strips event handlers from allowed tags" do
      for handler <- ~w[onclick onmouseover onerror] do
        html = ~s[<p #{handler}="evil()">text</p>]
        result = Native.sanitize_federation(html)
        refute result =~ handler
        refute result =~ "evil"
        assert result =~ "text"
      end
    end

    test "strips img tag (not in federation allowlist)" do
      html = ~s[<img src="https://example.com/img.png" alt="pic">]
      result = Native.sanitize_federation(html)
      refute result =~ "img"
    end

    test "strips table tags (not in federation allowlist)" do
      html = "<table><tr><td>data</td></tr></table>"
      result = Native.sanitize_federation(html)
      refute result =~ "table"
      refute result =~ "<tr>"
      refute result =~ "<td>"
    end

    test "rejects javascript: URI scheme" do
      html = ~s[<a href="javascript:alert(1)">click</a>]
      result = Native.sanitize_federation(html)
      refute result =~ "javascript"
    end

    test "rejects data: URI scheme" do
      html = ~s[<a href="data:text/html,payload">click</a>]
      result = Native.sanitize_federation(html)
      refute result =~ "data:"
    end

    test "rejects entity-encoded javascript: URI" do
      html = ~s[<a href="&#106;avascript:alert(1)">click</a>]
      result = Native.sanitize_federation(html)
      refute result =~ "javascript"
      refute result =~ "alert"
    end

    test "denies relative URLs" do
      html = ~s[<a href="/admin/settings">settings</a>]
      result = Native.sanitize_federation(html)
      refute result =~ "href"
      assert result =~ "settings"
    end

    test "denies protocol-relative URLs" do
      html = ~s[<a href="//evil.example/payload">click</a>]
      result = Native.sanitize_federation(html)
      refute result =~ "//evil.example"
    end

    test "adds rel nofollow noopener noreferrer to links" do
      html = ~s[<a href="https://example.com">link</a>]
      result = Native.sanitize_federation(html)
      assert result =~ ~s[rel="nofollow noopener noreferrer"]
    end

    test "strips HTML comments" do
      html = "<p>Hello</p><!-- secret --><p>World</p>"
      result = Native.sanitize_federation(html)
      refute result =~ "<!--"
      refute result =~ "secret"
    end

    test "handles empty string" do
      assert "" == Native.sanitize_federation("")
    end

    test "handles plain text" do
      assert "Hello World" == Native.sanitize_federation("Hello World")
    end
  end

  # --- sanitize_markdown/1 ---

  describe "sanitize_markdown/1" do
    test "preserves federation tags plus table, img" do
      html =
        "<p><strong>bold</strong></p><table><thead><tr><th>h</th></tr></thead><tbody><tr><td>d</td></tr></tbody></table>"

      result = Native.sanitize_markdown(html)
      assert result =~ "<table>"
      assert result =~ "<thead>"
      assert result =~ "<tbody>"
      assert result =~ "<tr>"
      assert result =~ "<th>"
      assert result =~ "<td>"
    end

    test "preserves img[src, alt] and strips img[onerror]" do
      html = ~s[<img src="https://example.com/img.png" alt="pic" onerror="evil()">]
      result = Native.sanitize_markdown(html)
      assert result =~ "src="
      assert result =~ "alt="
      refute result =~ "onerror"
      refute result =~ "evil"
    end

    test "preserves code[class] matching language pattern" do
      html = ~s[<code class="language-elixir">code</code>]
      result = Native.sanitize_markdown(html)
      assert result =~ ~s[class="language-elixir"]
    end

    test "strips code[class] not matching language pattern" do
      html = ~s[<code class="malicious-class">code</code>]
      result = Native.sanitize_markdown(html)
      refute result =~ "malicious-class"
      assert result =~ "<code>"
    end

    test "allows mailto: URI scheme" do
      html = ~s[<a href="mailto:alice@example.com">email</a>]
      result = Native.sanitize_markdown(html)
      assert result =~ "mailto:alice@example.com"
    end

    test "allows relative URLs (unlike federation)" do
      html = ~s[<a href="/local/page">link</a>]
      result = Native.sanitize_markdown(html)
      assert result =~ ~s[href="/local/page"]
    end

    test "adds rel nofollow noopener (no noreferrer)" do
      html = ~s[<a href="https://example.com">link</a>]
      result = Native.sanitize_markdown(html)
      assert result =~ ~s[rel="nofollow noopener"]
      # Should NOT have noreferrer (federation has it, markdown does not)
      refute result =~ "noreferrer"
    end

    test "strips dangerous tags same as federation" do
      for tag <- ~w[script style iframe object embed form input textarea svg math] do
        html = "<#{tag}>content</#{tag}>"
        result = Native.sanitize_markdown(html)
        refute result =~ tag, "Expected #{tag} to be stripped in markdown mode"
      end
    end

    test "span[class] is NOT allowed in markdown mode" do
      html = ~s[<span class="h-card">text</span>]
      result = Native.sanitize_markdown(html)
      refute result =~ "h-card"
    end

    test "handles language class with special chars" do
      for class <- ~w[language-c++ language-c_sharp language-f-sharp] do
        html = ~s[<code class="#{class}">code</code>]
        result = Native.sanitize_markdown(html)
        assert result =~ class, "Expected #{class} to be preserved"
      end
    end
  end

  # --- strip_tags/1 ---

  describe "strip_tags/1" do
    test "strips all HTML tags and preserves text content" do
      html = "<p>Hello <strong>World</strong></p>"
      assert "Hello World" == Native.strip_tags(html)
    end

    test "strips HTML comments" do
      html = "Hello <!-- comment --> World"
      result = Native.strip_tags(html)
      refute result =~ "<!--"
      refute result =~ "comment"
      assert result =~ "Hello"
      assert result =~ "World"
    end

    test "handles empty string" do
      assert "" == Native.strip_tags("")
    end

    test "handles plain text" do
      assert "Hello World" == Native.strip_tags("Hello World")
    end

    test "strips nested HTML" do
      html = "<div><p><strong><em>deep</em></strong></p></div>"
      assert "deep" == Native.strip_tags(html)
    end

    test "preserves HTML entities as text" do
      html = "<p>1 &lt; 2 &amp; 3 &gt; 0</p>"
      result = Native.strip_tags(html)
      assert result =~ "&lt;"
      assert result =~ "&amp;"
      assert result =~ "&gt;"
    end
  end
end
