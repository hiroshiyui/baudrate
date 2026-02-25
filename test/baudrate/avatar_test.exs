defmodule Baudrate.AvatarTest do
  use ExUnit.Case, async: true

  alias Baudrate.Avatar

  @avatar_dir Path.join([:code.priv_dir(:baudrate), "static", "uploads", "avatars"])

  setup do
    # Create test images in a temp directory
    tmp_dir = Path.join(System.tmp_dir!(), "avatar_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    {:ok, png_img} = Image.new(200, 200, color: [255, 100, 50])
    png_path = Path.join(tmp_dir, "test.png")
    Image.write!(png_img, png_path)

    {:ok, jpg_img} = Image.new(300, 200, color: [0, 128, 255])
    jpg_path = Path.join(tmp_dir, "test.jpg")
    Image.write!(jpg_img, jpg_path)

    {:ok, webp_img} = Image.new(150, 150, color: [50, 200, 100])
    webp_path = Path.join(tmp_dir, "test.webp")
    Image.write!(webp_img, webp_path)

    fake_path = Path.join(tmp_dir, "fake.jpg")
    File.write!(fake_path, "<html><body>not an image</body></html>")

    tiny_path = Path.join(tmp_dir, "tiny.bin")
    File.write!(tiny_path, "abc")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{
      tmp_dir: tmp_dir,
      png_path: png_path,
      jpg_path: jpg_path,
      webp_path: webp_path,
      fake_path: fake_path,
      tiny_path: tiny_path
    }
  end

  defp cleanup_avatar(avatar_id) do
    Avatar.delete_avatar(avatar_id)
  end

  describe "generate_avatar_id/0" do
    test "returns a 64-character lowercase hex string" do
      id = Avatar.generate_avatar_id()
      assert String.length(id) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, id)
    end

    test "generates unique IDs" do
      ids = for _ <- 1..10, do: Avatar.generate_avatar_id()
      assert length(Enum.uniq(ids)) == 10
    end
  end

  describe "avatar_url/2" do
    test "returns exact path when file exists", %{png_path: png_path} do
      {:ok, avatar_id} = Avatar.process_upload(png_path, nil)

      assert Avatar.avatar_url(avatar_id, 48) == "/uploads/avatars/#{avatar_id}/48.webp"
      assert Avatar.avatar_url(avatar_id, 36) == "/uploads/avatars/#{avatar_id}/36.webp"
      assert Avatar.avatar_url(avatar_id, 24) == "/uploads/avatars/#{avatar_id}/24.webp"

      cleanup_avatar(avatar_id)
    end

    test "falls back to next larger size when file missing" do
      # "abc123" doesn't exist on disk — fallback kicks in
      assert Avatar.avatar_url("abc123", 48) == "/uploads/avatars/abc123/48.webp"
      assert Avatar.avatar_url("abc123", 36) == "/uploads/avatars/abc123/48.webp"
      assert Avatar.avatar_url("abc123", 24) == "/uploads/avatars/abc123/36.webp"
    end
  end

  describe "delete_avatar/1" do
    test "returns :ok for nil" do
      assert Avatar.delete_avatar(nil) == :ok
    end

    test "returns :ok for nonexistent avatar_id" do
      assert Avatar.delete_avatar("nonexistent_id") == :ok
    end

    test "removes avatar directory", %{png_path: png_path} do
      {:ok, avatar_id} = Avatar.process_upload(png_path, nil)
      assert File.dir?(Path.join(@avatar_dir, avatar_id))

      assert Avatar.delete_avatar(avatar_id) == :ok
      refute File.dir?(Path.join(@avatar_dir, avatar_id))
    end
  end

  describe "process_upload/2 with valid images" do
    test "processes PNG and creates 48x48 and 36x36 WebP files", %{png_path: png_path} do
      crop = %{"x" => 0.1, "y" => 0.1, "width" => 0.8, "height" => 0.8}
      assert {:ok, avatar_id} = Avatar.process_upload(png_path, crop)

      path48 = Path.join([@avatar_dir, avatar_id, "48.webp"])
      path36 = Path.join([@avatar_dir, avatar_id, "36.webp"])
      assert File.exists?(path48)
      assert File.exists?(path36)

      {:ok, img48} = Image.open(path48)
      {:ok, img36} = Image.open(path36)
      assert {48, 48, _} = Image.shape(img48)
      assert {36, 36, _} = Image.shape(img36)

      cleanup_avatar(avatar_id)
    end

    test "processes JPEG", %{jpg_path: jpg_path} do
      crop = %{"x" => 0.0, "y" => 0.0, "width" => 1.0, "height" => 1.0}
      assert {:ok, avatar_id} = Avatar.process_upload(jpg_path, crop)

      path48 = Path.join([@avatar_dir, avatar_id, "48.webp"])
      assert File.exists?(path48)

      cleanup_avatar(avatar_id)
    end

    test "processes WebP", %{webp_path: webp_path} do
      assert {:ok, avatar_id} = Avatar.process_upload(webp_path, nil)

      path48 = Path.join([@avatar_dir, avatar_id, "48.webp"])
      assert File.exists?(path48)

      cleanup_avatar(avatar_id)
    end

    test "crops to center square when no crop params given", %{jpg_path: jpg_path} do
      # jpg_path is 300x200, center square should be 200x200 starting at (50, 0)
      assert {:ok, avatar_id} = Avatar.process_upload(jpg_path, nil)

      path48 = Path.join([@avatar_dir, avatar_id, "48.webp"])
      {:ok, img} = Image.open(path48)
      assert {48, 48, _} = Image.shape(img)

      cleanup_avatar(avatar_id)
    end

    test "returns a 64-char hex avatar_id", %{png_path: png_path} do
      {:ok, avatar_id} = Avatar.process_upload(png_path, nil)

      assert String.length(avatar_id) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, avatar_id)

      cleanup_avatar(avatar_id)
    end
  end

  describe "process_upload/2 rejection" do
    test "rejects file with invalid magic bytes (HTML disguised as .jpg)", %{fake_path: fake_path} do
      assert {:error, :invalid_image} = Avatar.process_upload(fake_path, nil)
    end

    test "rejects file that is too small for magic bytes check", %{tiny_path: tiny_path} do
      assert {:error, :invalid_image} = Avatar.process_upload(tiny_path, nil)
    end

    test "rejects nonexistent file" do
      assert {:error, :enoent} = Avatar.process_upload("/tmp/does_not_exist.png", nil)
    end

    test "does not leave files behind on rejection", %{fake_path: fake_path} do
      avatar_count_before = count_avatar_dirs()
      Avatar.process_upload(fake_path, nil)
      assert count_avatar_dirs() == avatar_count_before
    end
  end

  describe "process_upload/2 crop coordinates" do
    test "handles full-image crop", %{png_path: png_path} do
      crop = %{"x" => 0.0, "y" => 0.0, "width" => 1.0, "height" => 1.0}
      assert {:ok, avatar_id} = Avatar.process_upload(png_path, crop)
      cleanup_avatar(avatar_id)
    end

    test "handles small crop region", %{png_path: png_path} do
      crop = %{"x" => 0.25, "y" => 0.25, "width" => 0.5, "height" => 0.5}
      assert {:ok, avatar_id} = Avatar.process_upload(png_path, crop)
      cleanup_avatar(avatar_id)
    end

    test "clamps out-of-bounds crop coordinates", %{png_path: png_path} do
      crop = %{"x" => 0.9, "y" => 0.9, "width" => 0.5, "height" => 0.5}
      assert {:ok, avatar_id} = Avatar.process_upload(png_path, crop)
      cleanup_avatar(avatar_id)
    end
  end

  defp count_avatar_dirs do
    case File.ls(@avatar_dir) do
      {:ok, entries} -> length(entries)
      {:error, :enoent} -> 0
    end
  end
end
