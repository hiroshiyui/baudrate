defmodule Baudrate.Content.ArticleImageStorageTest do
  use Baudrate.DataCase

  alias Baudrate.Content.ArticleImageStorage

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "article_img_storage_#{System.unique_integer([:positive])}"
      )

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
    test "processes PNG and returns WebP with correct dimensions", %{png_path: png_path} do
      assert {:ok, result} = ArticleImageStorage.process_upload(png_path)

      assert result.filename =~ ~r/^[0-9a-f]{64}\.webp$/
      assert File.exists?(result.storage_path)
      assert result.width == 200
      assert result.height == 200

      cleanup_image(result)
    end

    test "downscales large images to max 1024px on longest side", %{large_path: large_path} do
      assert {:ok, result} = ArticleImageStorage.process_upload(large_path)

      assert max(result.width, result.height) <= 1024
      # 2048x1536 should scale down with longest side at 1024
      assert result.width == 1024 or result.height == 1024

      cleanup_image(result)
    end

    test "preserves aspect ratio when downscaling", %{large_path: large_path} do
      assert {:ok, result} = ArticleImageStorage.process_upload(large_path)

      # Original 2048x1536 is 4:3 ratio; width should be larger than height
      assert result.width > result.height

      cleanup_image(result)
    end

    test "does not upscale small images", %{png_path: png_path} do
      assert {:ok, result} = ArticleImageStorage.process_upload(png_path)

      assert result.width == 200
      assert result.height == 200

      cleanup_image(result)
    end

    test "processes WebP input", %{webp_path: webp_path} do
      assert {:ok, result} = ArticleImageStorage.process_upload(webp_path)

      assert result.filename =~ ~r/\.webp$/
      assert File.exists?(result.storage_path)
      assert result.width == 150
      assert result.height == 150

      cleanup_image(result)
    end

    test "generates unique filenames for each upload", %{png_path: png_path} do
      {:ok, r1} = ArticleImageStorage.process_upload(png_path)
      {:ok, r2} = ArticleImageStorage.process_upload(png_path)

      refute r1.filename == r2.filename
      refute r1.storage_path == r2.storage_path

      cleanup_image(r1)
      cleanup_image(r2)
    end

    test "stores files in the upload directory", %{png_path: png_path} do
      {:ok, result} = ArticleImageStorage.process_upload(png_path)

      assert String.starts_with?(result.storage_path, ArticleImageStorage.upload_dir())
      assert result.storage_path == Path.join(ArticleImageStorage.upload_dir(), result.filename)

      cleanup_image(result)
    end

    test "returns map with all required keys", %{png_path: png_path} do
      assert {:ok, result} = ArticleImageStorage.process_upload(png_path)

      assert Map.has_key?(result, :filename)
      assert Map.has_key?(result, :storage_path)
      assert Map.has_key?(result, :width)
      assert Map.has_key?(result, :height)
      assert is_binary(result.filename)
      assert is_binary(result.storage_path)
      assert is_integer(result.width)
      assert is_integer(result.height)

      cleanup_image(result)
    end
  end

  describe "process_upload/1 rejection" do
    test "rejects file with invalid magic bytes", %{fake_path: fake_path} do
      assert {:error, :invalid_image} = ArticleImageStorage.process_upload(fake_path)
    end

    test "rejects file too small for magic bytes check", %{tiny_path: tiny_path} do
      assert {:error, :invalid_image} = ArticleImageStorage.process_upload(tiny_path)
    end

    test "rejects empty file", %{tmp_dir: tmp_dir} do
      empty_path = Path.join(tmp_dir, "empty.png")
      File.write!(empty_path, "")

      assert {:error, :invalid_image} = ArticleImageStorage.process_upload(empty_path)
    end

    test "rejects image smaller than 16x16", %{tiny_img_path: tiny_img_path} do
      assert {:error, :image_too_small} = ArticleImageStorage.process_upload(tiny_img_path)
    end

    test "rejects image with only one dimension below 16px", %{tmp_dir: tmp_dir} do
      {:ok, narrow_img} = Image.new(100, 10, color: [255, 0, 0])
      narrow_path = Path.join(tmp_dir, "narrow.png")
      Image.write!(narrow_img, narrow_path)

      assert {:error, :image_too_small} = ArticleImageStorage.process_upload(narrow_path)
    end

    test "returns error for nonexistent file" do
      assert {:error, :enoent} = ArticleImageStorage.process_upload("/tmp/does_not_exist.png")
    end

    test "rejects GIF-disguised text file", %{tmp_dir: tmp_dir} do
      disguised_path = Path.join(tmp_dir, "disguised.gif")
      # Write enough bytes but with wrong magic bytes
      File.write!(disguised_path, String.duplicate("x", 20))

      assert {:error, :invalid_image} = ArticleImageStorage.process_upload(disguised_path)
    end
  end

  describe "delete_image/1" do
    test "removes file from disk", %{png_path: png_path} do
      {:ok, result} = ArticleImageStorage.process_upload(png_path)
      assert File.exists?(result.storage_path)

      assert :ok = ArticleImageStorage.delete_image(result)
      refute File.exists?(result.storage_path)
    end

    test "returns :ok when file does not exist on disk" do
      assert :ok =
               ArticleImageStorage.delete_image(%{
                 storage_path: "/tmp/nonexistent_#{System.unique_integer([:positive])}.webp"
               })
    end

    test "returns :ok when file was already deleted", %{png_path: png_path} do
      {:ok, result} = ArticleImageStorage.process_upload(png_path)
      File.rm!(result.storage_path)

      assert :ok = ArticleImageStorage.delete_image(result)
    end

    test "returns :ok for nil input" do
      assert :ok = ArticleImageStorage.delete_image(nil)
    end

    test "returns :ok for map without storage_path" do
      assert :ok = ArticleImageStorage.delete_image(%{})
    end

    test "returns :ok for map with non-binary storage_path" do
      assert :ok = ArticleImageStorage.delete_image(%{storage_path: nil})
    end
  end

  describe "image_url/1" do
    test "returns correct URL path for a filename" do
      assert ArticleImageStorage.image_url("abc123.webp") ==
               "/uploads/article_images/abc123.webp"
    end

    test "returns URL path preserving the given filename" do
      hex_name = "deadbeef0123456789abcdef0123456789abcdef0123456789abcdef01234567.webp"

      assert ArticleImageStorage.image_url(hex_name) ==
               "/uploads/article_images/#{hex_name}"
    end

    test "works with process_upload result filename", %{png_path: png_path} do
      {:ok, result} = ArticleImageStorage.process_upload(png_path)

      url = ArticleImageStorage.image_url(result.filename)
      assert url == "/uploads/article_images/#{result.filename}"

      cleanup_image(result)
    end
  end

  describe "upload_dir/0" do
    test "returns a path ending with the expected directory structure" do
      dir = ArticleImageStorage.upload_dir()
      assert String.ends_with?(dir, "priv/static/uploads/article_images")
    end

    test "returns a consistent value across calls" do
      assert ArticleImageStorage.upload_dir() == ArticleImageStorage.upload_dir()
    end

    test "returns an absolute path" do
      assert String.starts_with?(ArticleImageStorage.upload_dir(), "/")
    end
  end
end
