defmodule BaudrateWeb.ImageAltFallbackTest do
  @moduledoc """
  ADR 0061: `alt=""` is a claim, not a blank.

  A screen reader honours `alt=""` by skipping the image without a word, so a
  remote comment whose peer sent no description used to render a picture that
  no reader was told existed.
  """
  use ExUnit.Case, async: true

  alias BaudrateWeb.ImageAltFallback

  describe "what it fills in" do
    test "an empty alt, which claims the image is decorative" do
      html = ~s(<p><img src="/media/abc/def" alt="" loading="lazy" /></p>)

      filled = ImageAltFallback.fill(html)

      refute filled =~ ~s(alt="")
      assert filled =~ "Image with no description"
    end

    test "a missing alt, where the reader otherwise gets the file name" do
      html = ~s(<p><img src="/media/abc/def" loading="lazy" /></p>)

      filled = ImageAltFallback.fill(html)

      assert filled =~ ~s(alt="Image with no description")
      # The rest of the tag survives intact.
      assert filled =~ ~s(src="/media/abc/def")
      assert filled =~ ~s(loading="lazy")
    end

    test "every image in the document, not just the first" do
      html = ~s(<img src="/a" alt=""><img src="/b"><img src="/c" alt="">)

      filled = ImageAltFallback.fill(html)

      assert length(String.split(filled, "Image with no description")) == 4
    end
  end

  describe "what it leaves alone" do
    test "an image the uploader or the peer described" do
      html = ~s(<img src="/media/abc/def" alt="a cat on a fence" />)

      assert ImageAltFallback.fill(html) == html
    end

    test "a described image standing beside an undescribed one" do
      html = ~s(<img src="/a" alt="a cat on a fence"><img src="/b" alt="">)

      filled = ImageAltFallback.fill(html)

      assert filled =~ ~s(alt="a cat on a fence")
      assert filled =~ ~s(alt="Image with no description")
    end

    test "everything that is not an img" do
      html = ~s(<p>alt="" is not an image</p><a href="/x">link</a>)

      assert ImageAltFallback.fill(html) == html
    end

    test "nil, empty and non-binary input" do
      assert ImageAltFallback.fill(nil) == nil
      assert ImageAltFallback.fill("") == ""
      assert ImageAltFallback.fill(:not_html) == :not_html
    end
  end

  describe "running it twice" do
    test "is the same as running it once" do
      html = ~s(<img src="/a" alt=""><img src="/b">)

      once = ImageAltFallback.fill(html)

      assert ImageAltFallback.fill(once) == once
    end
  end

  describe "the pass that runs before it" do
    test "a proxied remote image still gets a description" do
      # SafeHTML runs Media.Rewriter first, so what reaches this pass has
      # already had its src rewritten. The two must not interfere.
      html =
        ~s(<img src="https://remote.example/pic.jpg" alt="">)
        |> Baudrate.Media.Rewriter.rewrite_img_src()
        |> ImageAltFallback.fill()

      assert html =~ "/media/"
      assert html =~ ~s(alt="Image with no description")
      refute html =~ "remote.example"
    end
  end
end
