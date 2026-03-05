defmodule Baudrate.Content.LinkPreview.ImageProxyTest do
  use ExUnit.Case, async: true

  alias Baudrate.Content.LinkPreview.ImageProxy
  alias Baudrate.Federation.HTTPClient

  @url_hash :crypto.hash(:sha256, "https://example.com/test")

  describe "proxy_image/2" do
    test "re-encodes a valid JPEG to WebP and returns serving path" do
      jpeg_binary = create_test_jpeg()

      Req.Test.stub(HTTPClient, fn conn ->
        Req.Test.text(conn, jpeg_binary)
      end)

      # Use http:// to skip SSRF validation (Req.Test intercepts before network)
      url = "https://example.com/image.jpg"
      assert {:ok, serving_path} = ImageProxy.proxy_image(url, @url_hash)
      assert is_binary(serving_path)
      assert String.ends_with?(serving_path, ".webp")
      assert String.contains?(serving_path, "/uploads/link_preview_images/")

      # Cleanup
      ImageProxy.delete_image(serving_path)
    end

    test "rejects non-image content" do
      Req.Test.stub(HTTPClient, fn conn ->
        Req.Test.text(conn, "this is not an image at all, just plain text content")
      end)

      url = "https://example.com/not-image.txt"
      assert {:error, :invalid_image} = ImageProxy.proxy_image(url, @url_hash)
    end
  end

  describe "delete_image/1" do
    test "returns :ok for nil" do
      assert :ok = ImageProxy.delete_image(nil)
    end

    test "returns :ok for non-existent file" do
      assert :ok = ImageProxy.delete_image("/uploads/link_preview_images/nonexistent.webp")
    end
  end

  # Creates a minimal valid JPEG binary
  defp create_test_jpeg do
    {:ok, image} = Image.new(2, 2, color: :red)
    {:ok, binary} = Image.write(image, :memory, suffix: ".jpg")
    binary
  end
end
