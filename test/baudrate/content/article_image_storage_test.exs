defmodule Baudrate.Content.ArticleImageStorageTest do
  use ExUnit.Case, async: true

  alias Baudrate.Content.ArticleImageStorage

  @upload_dir ArticleImageStorage.upload_dir()

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "article_img_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    {:ok, png_img} = Image.new(200, 200, color: [255, 100, 50])
    png_path = Path.join(tmp_dir, "test.png")
    Image.write!(png_img, png_path)

    {:ok, large_img} = Image.new(2048, 1536, color: [0, 128, 255])
    large_path = Path.join(tmp_dir, "large.jpg")
    Image.write!(large_img, large_path)

    {:ok, webp_img} = Image.new(150, 150, color: [50, 200, 100])
    webp_path = Path.join(tmp_dir, "test.webp")
    Image.write!(webp_img, webp_path)

    {:ok, tiny_img} = Image.new(8, 8, color: [255, 0, 0])
    tiny_img_path = Path.join(tmp_dir, "tiny_img.png")
    Image.write!(tiny_img, tiny_img_path)

    fake_path = Path.join(tmp_dir, "fake.jpg")
    File.write!(fake_path, "<html><body>not an image</body></html>")

    tiny_path = Path.join(tmp_dir, "tiny.bin")
    File.write!(tiny_path, "abc")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{
      tmp_dir: tmp_dir,
      png_path: png_path,
      large_path: large_path,
      webp_path: webp_path,
      tiny_img_path: tiny_img_path,
      fake_path: fake_path,
      tiny_path: tiny_path
    }
  end

  defp cleanup_image(result) do
    ArticleImageStorage.delete_image(result)
  end

  describe "process_upload/1" do
    test "processes PNG and returns WebP with dimensions", %{png_path: png_path} do
      assert {:ok, result} = ArticleImageStorage.process_upload(png_path)

      assert result.filename =~ ~r/^[0-9a-f]{64}\.webp$/
      assert File.exists?(result.storage_path)
      assert result.width == 200
      assert result.height == 200

      cleanup_image(result)
    end

    test "downscales large images to max 1024px", %{large_path: large_path} do
      assert {:ok, result} = ArticleImageStorage.process_upload(large_path)

      assert max(result.width, result.height) <= 1024
      # 2048x1536 should become 1024x768 (aspect preserved)
      assert result.width == 1024 or result.height == 1024

      cleanup_image(result)
    end

    test "preserves small images without upscaling", %{png_path: png_path} do
      assert {:ok, result} = ArticleImageStorage.process_upload(png_path)

      assert result.width == 200
      assert result.height == 200

      cleanup_image(result)
    end

    test "processes WebP input", %{webp_path: webp_path} do
      assert {:ok, result} = ArticleImageStorage.process_upload(webp_path)

      assert result.filename =~ ~r/\.webp$/
      assert File.exists?(result.storage_path)

      cleanup_image(result)
    end

    test "generates random unique filenames", %{png_path: png_path} do
      {:ok, r1} = ArticleImageStorage.process_upload(png_path)
      {:ok, r2} = ArticleImageStorage.process_upload(png_path)

      assert r1.filename != r2.filename

      cleanup_image(r1)
      cleanup_image(r2)
    end

    test "stores files in article_images directory", %{png_path: png_path} do
      {:ok, result} = ArticleImageStorage.process_upload(png_path)

      assert String.starts_with?(result.storage_path, @upload_dir)

      cleanup_image(result)
    end
  end

  describe "process_upload/1 rejection" do
    test "rejects file with invalid magic bytes", %{fake_path: fake_path} do
      assert {:error, :invalid_image} = ArticleImageStorage.process_upload(fake_path)
    end

    test "rejects file too small for magic bytes", %{tiny_path: tiny_path} do
      assert {:error, :invalid_image} = ArticleImageStorage.process_upload(tiny_path)
    end

    test "rejects image smaller than 16x16", %{tiny_img_path: tiny_img_path} do
      assert {:error, :image_too_small} = ArticleImageStorage.process_upload(tiny_img_path)
    end

    test "rejects nonexistent file" do
      assert {:error, :enoent} = ArticleImageStorage.process_upload("/tmp/does_not_exist.png")
    end
  end

  describe "image_url/1" do
    test "returns correct path" do
      assert ArticleImageStorage.image_url("abc123.webp") ==
               "/uploads/article_images/abc123.webp"
    end
  end

  describe "delete_image/1" do
    test "removes file from disk", %{png_path: png_path} do
      {:ok, result} = ArticleImageStorage.process_upload(png_path)
      assert File.exists?(result.storage_path)

      assert :ok = ArticleImageStorage.delete_image(result)
      refute File.exists?(result.storage_path)
    end

    test "returns :ok for nil" do
      assert :ok = ArticleImageStorage.delete_image(nil)
    end

    test "returns :ok when file already deleted", %{png_path: png_path} do
      {:ok, result} = ArticleImageStorage.process_upload(png_path)
      File.rm!(result.storage_path)

      assert :ok = ArticleImageStorage.delete_image(result)
    end
  end
end
