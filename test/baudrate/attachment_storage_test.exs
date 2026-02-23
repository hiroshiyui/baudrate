defmodule Baudrate.AttachmentStorageTest do
  use ExUnit.Case, async: true

  alias Baudrate.AttachmentStorage

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "attachment_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Real images via Image library
    {:ok, png_img} = Image.new(200, 200, color: [255, 100, 50])
    png_path = Path.join(tmp_dir, "test.png")
    Image.write!(png_img, png_path)

    {:ok, jpg_img} = Image.new(150, 150, color: [0, 128, 255])
    jpg_path = Path.join(tmp_dir, "test.jpg")
    Image.write!(jpg_img, jpg_path)

    {:ok, webp_img} = Image.new(120, 120, color: [50, 200, 100])
    webp_path = Path.join(tmp_dir, "test.webp")
    Image.write!(webp_img, webp_path)

    {:ok, gif_img} = Image.new(80, 80, color: [200, 50, 150])
    gif_path = Path.join(tmp_dir, "test.gif")
    Image.write!(gif_img, gif_path)

    # Fake PDF with correct magic bytes
    pdf_path = Path.join(tmp_dir, "test.pdf")
    File.write!(pdf_path, <<0x25, 0x50, 0x44, 0x46>> <> "-1.4 fake pdf content")

    # Fake ZIP with correct magic bytes
    zip_path = Path.join(tmp_dir, "test.zip")
    File.write!(zip_path, <<0x50, 0x4B, 0x03, 0x04>> <> "fake zip content")

    # Text files
    txt_path = Path.join(tmp_dir, "test.txt")
    File.write!(txt_path, "Hello, world!")

    md_path = Path.join(tmp_dir, "test.md")
    File.write!(md_path, "# Heading\n\nParagraph.")

    # Disguised file: HTML content saved as .jpg
    disguised_path = Path.join(tmp_dir, "disguised.jpg")
    File.write!(disguised_path, "<html><body>not an image</body></html>")

    # Too-small file (<4 bytes)
    tiny_path = Path.join(tmp_dir, "tiny.bin")
    File.write!(tiny_path, "abc")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{
      tmp_dir: tmp_dir,
      png_path: png_path,
      jpg_path: jpg_path,
      webp_path: webp_path,
      gif_path: gif_path,
      pdf_path: pdf_path,
      zip_path: zip_path,
      txt_path: txt_path,
      md_path: md_path,
      disguised_path: disguised_path,
      tiny_path: tiny_path
    }
  end

  defp cleanup(result), do: AttachmentStorage.delete_attachment(result)

  # --- process_upload/3 valid files ---

  describe "process_upload/3 valid files" do
    test "processes PNG image", %{png_path: path} do
      assert {:ok, result} = AttachmentStorage.process_upload(path, "photo.png", "image/png")
      assert result.filename =~ ~r/^[0-9a-f]{32}_/
      assert result.content_type == "image/png"
      assert File.exists?(result.storage_path)
      assert result.size > 0
      cleanup(result)
    end

    test "processes JPEG image", %{jpg_path: path} do
      assert {:ok, result} = AttachmentStorage.process_upload(path, "photo.jpg", "image/jpeg")
      assert result.filename =~ ~r/^[0-9a-f]{32}_/
      assert result.content_type == "image/jpeg"
      cleanup(result)
    end

    test "processes WebP image", %{webp_path: path} do
      assert {:ok, result} = AttachmentStorage.process_upload(path, "photo.webp", "image/webp")
      assert result.content_type == "image/webp"
      cleanup(result)
    end

    test "processes GIF image", %{gif_path: path} do
      assert {:ok, result} = AttachmentStorage.process_upload(path, "anim.gif", "image/gif")
      assert result.content_type == "image/gif"
      cleanup(result)
    end

    test "processes PDF with correct magic bytes", %{pdf_path: path} do
      assert {:ok, result} =
               AttachmentStorage.process_upload(path, "document.pdf", "application/pdf")

      assert result.content_type == "application/pdf"
      cleanup(result)
    end

    test "processes ZIP with correct magic bytes", %{zip_path: path} do
      assert {:ok, result} =
               AttachmentStorage.process_upload(path, "archive.zip", "application/zip")

      assert result.content_type == "application/zip"
      cleanup(result)
    end

    test "processes text/plain without magic bytes", %{txt_path: path} do
      assert {:ok, result} = AttachmentStorage.process_upload(path, "notes.txt", "text/plain")
      assert result.content_type == "text/plain"
      cleanup(result)
    end

    test "processes text/markdown without magic bytes", %{md_path: path} do
      assert {:ok, result} = AttachmentStorage.process_upload(path, "readme.md", "text/markdown")
      assert result.content_type == "text/markdown"
      cleanup(result)
    end

    test "returns correct result shape", %{png_path: path} do
      assert {:ok, result} = AttachmentStorage.process_upload(path, "test.png", "image/png")
      assert Map.has_key?(result, :filename)
      assert Map.has_key?(result, :storage_path)
      assert Map.has_key?(result, :content_type)
      assert Map.has_key?(result, :size)
      cleanup(result)
    end

    test "generates unique filenames for repeated uploads", %{png_path: path} do
      {:ok, r1} = AttachmentStorage.process_upload(path, "same.png", "image/png")
      {:ok, r2} = AttachmentStorage.process_upload(path, "same.png", "image/png")
      assert r1.filename != r2.filename
      cleanup(r1)
      cleanup(r2)
    end

    test "non-image files are copied without re-encoding", %{pdf_path: path} do
      assert {:ok, result} =
               AttachmentStorage.process_upload(path, "doc.pdf", "application/pdf")

      # PDF should be a direct copy — verify content starts with PDF magic
      {:ok, content} = File.read(result.storage_path)
      assert binary_part(content, 0, 4) == <<0x25, 0x50, 0x44, 0x46>>
      cleanup(result)
    end
  end

  # --- process_upload/3 rejection (security-critical) ---

  describe "process_upload/3 rejection" do
    test "rejects mismatched magic bytes vs content_type (JPEG bytes claimed as PNG)", %{
      jpg_path: path
    } do
      assert {:error, :invalid_file_type} =
               AttachmentStorage.process_upload(path, "fake.png", "image/png")
    end

    test "rejects HTML content claimed as image/jpeg", %{disguised_path: path} do
      assert {:error, :invalid_file_type} =
               AttachmentStorage.process_upload(path, "disguised.jpg", "image/jpeg")
    end

    test "rejects file smaller than 4 bytes", %{tiny_path: path} do
      assert {:error, :invalid_file_type} =
               AttachmentStorage.process_upload(path, "tiny.bin", "image/png")
    end

    test "rejects nonexistent file path" do
      assert {:error, :enoent} =
               AttachmentStorage.process_upload(
                 "/tmp/does_not_exist_#{System.unique_integer([:positive])}",
                 "ghost.png",
                 "image/png"
               )
    end
  end

  # --- Filename sanitization ---

  describe "process_upload/3 filename sanitization" do
    test "path traversal: extracts basename only", %{png_path: path} do
      {:ok, result} =
        AttachmentStorage.process_upload(path, "../../../etc/evil.png", "image/png")

      refute result.filename =~ ".."
      refute result.filename =~ "/"
      cleanup(result)
    end

    test "non-word chars replaced with underscore", %{png_path: path} do
      {:ok, result} =
        AttachmentStorage.process_upload(path, "my file (1).png", "image/png")

      # The original name part should have spaces/parens replaced
      # Filename format: hex_sanitized_name
      [_hex, name_part] = String.split(result.filename, "_", parts: 2)
      refute name_part =~ " "
      refute name_part =~ "("
      refute name_part =~ ")"
      cleanup(result)
    end

    test "long filenames truncated to 100 chars", %{txt_path: path} do
      long_name = String.duplicate("a", 200) <> ".txt"

      {:ok, result} =
        AttachmentStorage.process_upload(path, long_name, "text/plain")

      # hex prefix is 32 chars + underscore = 33, so original name part <= 100
      [_hex, name_part] = String.split(result.filename, "_", parts: 2)
      assert String.length(name_part) <= 100
      cleanup(result)
    end
  end

  # --- delete_attachment/1 ---

  describe "delete_attachment/1" do
    test "deletes the file from disk", %{png_path: path} do
      {:ok, result} = AttachmentStorage.process_upload(path, "del.png", "image/png")
      assert File.exists?(result.storage_path)

      assert :ok = AttachmentStorage.delete_attachment(result)
      refute File.exists?(result.storage_path)
    end

    test "returns :ok for already-deleted file", %{png_path: path} do
      {:ok, result} = AttachmentStorage.process_upload(path, "del.png", "image/png")
      File.rm!(result.storage_path)

      assert :ok = AttachmentStorage.delete_attachment(result)
    end

    test "returns :ok for nil input" do
      assert :ok = AttachmentStorage.delete_attachment(nil)
    end

    test "returns :ok for map without storage_path" do
      assert :ok = AttachmentStorage.delete_attachment(%{})
    end
  end

  # --- attachment_url/1 ---

  describe "attachment_url/1" do
    test "returns correct URL path" do
      assert "/uploads/attachments/abc123_file.png" ==
               AttachmentStorage.attachment_url("abc123_file.png")
    end
  end
end
