defmodule Baudrate.Media.RewriterTest do
  use ExUnit.Case, async: true

  alias Baudrate.Media.{Proxy, Rewriter}

  describe "rewrite_img_src/1" do
    test "rewrites an https img src" do
      html = ~s(<p><img src="https://remote.example/a.png" alt="x" /></p>)
      result = Rewriter.rewrite_img_src(html)

      refute result =~ "remote.example"
      assert result =~ ~s(src="/media/)
      assert result =~ ~s(alt="x")
    end

    test "rewrites an http img src" do
      html = ~s(<img src="http://remote.example/a.png">)
      assert Rewriter.rewrite_img_src(html) =~ ~s(src="/media/)
    end

    test "rewrites a protocol-relative img src" do
      html = ~s(<img src="//remote.example/a.png">)
      result = Rewriter.rewrite_img_src(html)

      refute result =~ "remote.example"
      assert result =~ ~s(src="/media/)
    end

    test "leaves local paths alone" do
      html = ~s(<img src="/uploads/article_images/abc.webp">)
      assert Rewriter.rewrite_img_src(html) == html
    end

    test "is idempotent" do
      html = ~s(<img src="https://remote.example/a.png">)
      once = Rewriter.rewrite_img_src(html)
      assert Rewriter.rewrite_img_src(once) == once
    end

    test "does not touch anchor hrefs" do
      # A link issues no request until clicked, so it stays canonical.
      html = ~s(<a href="https://remote.example/page">link</a>)
      assert Rewriter.rewrite_img_src(html) == html
    end

    test "signs the unescaped URL so query strings round-trip" do
      html = ~s(<img src="https://remote.example/a.png?w=1&amp;h=2">)
      result = Rewriter.rewrite_img_src(html)

      [_, sig, encoded] = Regex.run(~r{src="/media/([^/]+)/([^"]+)"}, result)
      assert {:ok, "https://remote.example/a.png?w=1&h=2"} = Proxy.verify(sig, encoded)
    end

    test "rewrites every img in a document" do
      html = """
      <p><img src="https://a.example/1.png"></p>
      <p><img src="https://b.example/2.png"></p>
      """

      result = Rewriter.rewrite_img_src(html)

      refute result =~ "a.example"
      refute result =~ "b.example"
      assert length(Regex.scan(~r{src="/media/}, result)) == 2
    end

    test "passes nil and empty through" do
      assert Rewriter.rewrite_img_src(nil) == nil
      assert Rewriter.rewrite_img_src("") == ""
    end
  end
end
