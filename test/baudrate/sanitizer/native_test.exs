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

    test "preserves anchor with safe classes: hashtag, mention, u-url" do
      for class <- ~w[hashtag mention u-url] do
        html = ~s[<a href="https://example.com" class="#{class}">link</a>]
        result = Native.sanitize_federation(html)
        assert result =~ ~s[class="#{class}"], "Expected #{class} to be preserved on <a>"
      end
    end

    test "preserves Mastodon mention anchor with u-url mention classes" do
      html =
        ~s[<span class="h-card"><a href="https://mastodon.social/@eff" class="u-url mention">@eff</a></span>]

      result = Native.sanitize_federation(html)
      assert result =~ ~s[class="u-url mention"]
      assert result =~ ~s[class="h-card"]
    end

    test "strips unsafe class from anchor but keeps tag" do
      html = ~s[<a href="https://example.com" class="malicious">link</a>]
      result = Native.sanitize_federation(html)
      assert result =~ "<a "
      refute result =~ "malicious"
    end

    test "keeps only safe classes from mixed anchor class list" do
      html = ~s[<a href="https://example.com" class="mention evil u-url">link</a>]
      result = Native.sanitize_federation(html)
      assert result =~ "mention"
      assert result =~ "u-url"
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

  # --- decode_html_entities/1 ---

  describe "decode_html_entities/1" do
    test "decodes the five XML entities" do
      assert "& < > \" '" ==
               Native.decode_html_entities("&amp; &lt; &gt; &quot; &apos;")
    end

    test "decodes &#39; as apostrophe" do
      assert "it's" == Native.decode_html_entities("it&#39;s")
    end

    test "decodes &nbsp; as a regular space" do
      assert "hello world" == Native.decode_html_entities("hello&nbsp;world")
    end

    test "handles string with no entities unchanged" do
      assert "plain text" == Native.decode_html_entities("plain text")
    end

    test "handles empty string" do
      assert "" == Native.decode_html_entities("")
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

    test "trims leading and trailing &nbsp; entities" do
      html = "<p>&nbsp;Hello World&nbsp;</p>"
      assert "Hello World" == Native.strip_tags(html)
    end

    test "trims multiple consecutive leading and trailing &nbsp; entities" do
      html = "<p>&nbsp;&nbsp;Hello World&nbsp;&nbsp;</p>"
      assert "Hello World" == Native.strip_tags(html)
    end

    test "does not trim interior &nbsp; entities" do
      html = "<p>&nbsp;a&nbsp;b&nbsp;</p>"
      result = Native.strip_tags(html)
      assert result == "a&nbsp;b"
    end
  end

  # --- normalize_feed_html/1 ---

  describe "normalize_feed_html/1" do
    test "sanitizes HTML with the markdown allowlist" do
      html = "<p><strong>bold</strong> <em>italic</em></p>"
      result = Native.normalize_feed_html(html)
      assert result =~ "<strong>"
      assert result =~ "<em>"
    end

    test "strips disallowed tags like sanitize_markdown" do
      html = "<div><p>content</p></div><script>evil()</script>"
      result = Native.normalize_feed_html(html)
      refute result =~ "div"
      refute result =~ "script"
      assert result =~ "content"
    end

    test "removes empty <p> elements" do
      html = "<p>text</p><p></p><p>more</p>"
      result = Native.normalize_feed_html(html)
      assert result == "<p>text</p><p>more</p>"
    end

    test "removes whitespace-only <p> elements" do
      html = "<p>text</p><p>   </p><p>more</p>"
      result = Native.normalize_feed_html(html)
      assert result == "<p>text</p><p>more</p>"
    end

    test "removes &nbsp;-only <p> elements" do
      html = "<p>text</p><p>&nbsp;</p><p>more</p>"
      result = Native.normalize_feed_html(html)
      assert result == "<p>text</p><p>more</p>"
    end

    test "collapses 3+ consecutive <br> to 2" do
      html = "<p>a</p><br><br><br><br><p>b</p>"
      result = Native.normalize_feed_html(html)
      assert result =~ "<br><br>"
      refute result =~ "<br><br><br>"
    end

    test "preserves exactly 2 consecutive <br>" do
      html = "<p>a</p><br><br><p>b</p>"
      result = Native.normalize_feed_html(html)
      assert result =~ "<br><br>"
    end

    test "trims leading and trailing whitespace from result" do
      html = "  <p>hello</p>  "
      result = Native.normalize_feed_html(html)
      assert result == "<p>hello</p>"
    end

    test "handles empty string" do
      assert "" == Native.normalize_feed_html("")
    end

    test "replaces &nbsp; in text content with regular space" do
      html = "<p>word&nbsp;word</p>"
      result = Native.normalize_feed_html(html)
      assert result == "<p>word word</p>"
    end

    test "replaces standalone &nbsp; between block elements with regular space" do
      html = "<p>first</p>&nbsp;<p>second</p>"
      result = Native.normalize_feed_html(html)
      refute result =~ "&nbsp;"
      assert result =~ "first"
      assert result =~ "second"
    end

    test "replaces multiple &nbsp; entities with spaces" do
      html = "<p>a&nbsp;&nbsp;b</p>"
      result = Native.normalize_feed_html(html)
      assert result == "<p>a  b</p>"
    end
  end
end
