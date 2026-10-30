defmodule Baudrate.Media.ImageBoundsTest do
  @moduledoc """
  A byte cap is not a decode cap: the header of a 282-byte PNG can declare
  400 megapixels, and libvips decodes on first pixel access. Every re-encode
  pipeline refuses on the header, before any pixel exists.
  """

  use ExUnit.Case, async: true

  alias Baudrate.Media.ImageBounds

  # A valid 1×1 PNG whose IHDR is rewritten to declare `w × h`: the header
  # parses, the pixel data does not match it — exactly a decompression bomb's
  # shape, without the cost of making one.
  defp png_declaring(w, h) do
    {:ok, one} = Image.new(1, 1, color: [1, 2, 3])
    {:ok, bin} = Image.write(one, :memory, suffix: ".png")

    <<sig::binary-8, _len::32, "IHDR", _w::32, _h::32, tail::binary-5, _crc::32, rest::binary>> =
      bin

    ihdr = <<w::32, h::32>> <> tail
    sig <> <<13::32>> <> "IHDR" <> ihdr <> <<:erlang.crc32("IHDR" <> ihdr)::32>> <> rest
  end

  test "an image declaring more pixels than the cap is refused on its header" do
    {:ok, image} = Image.from_binary(png_declaring(20_000, 20_000))
    assert ImageBounds.validate(image) == {:error, :image_too_large}
  end

  test "an image with one side over the cap is refused however thin" do
    {:ok, image} = Image.from_binary(png_declaring(ImageBounds.max_side() + 1, 10))
    assert ImageBounds.validate(image) == {:error, :image_too_large}
  end

  test "an ordinary photo passes" do
    {:ok, image} = Image.from_binary(png_declaring(6_000, 4_000))
    assert ImageBounds.validate(image) == :ok
  end

  describe "every pipeline refuses before decoding" do
    setup do
      dir = Path.join(System.tmp_dir!(), "bounds_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "bomb.png")
      File.write!(path, png_declaring(20_000, 20_000))
      on_exit(fn -> File.rm_rf!(dir) end)
      %{path: path, bytes: File.read!(path)}
    end

    test "article and DM uploads", %{path: path} do
      assert {:error, :image_too_large} =
               Baudrate.Content.ArticleImageStorage.process_upload(path)
    end

    test "avatars", %{path: path} do
      assert {:error, :image_too_large} = Baudrate.Avatar.process_upload(path, nil)
    end
  end
end
