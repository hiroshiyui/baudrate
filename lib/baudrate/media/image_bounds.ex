defmodule Baudrate.Media.ImageBounds do
  @moduledoc """
  The one pixel-count gate in front of every libvips decode.

  A byte cap is not a decode cap: a flat-colour PNG declaring 30 000 × 30 000
  pixels is well under a megabyte on the wire and several gigabytes once
  decoded, and libvips decodes on first pixel access, so `Image.open/2` and
  `Image.from_binary/1` succeed and the thumbnail step is what runs the node
  out of memory. Every pipeline that re-encodes an image — member uploads
  (articles, direct messages, avatars), remote attachments, the media proxy,
  link-preview images and bot favicons — reads the header with
  `Image.shape/1` (cheap, no pixels) and refuses anything over the cap
  **before** rotating, cropping, thumbnailing or writing.
  """

  @max_pixels 40_000_000
  @max_side 12_000

  @doc "Pixel-count cap on a source image, before any decode."
  def max_pixels, do: @max_pixels

  @doc "Longest-side cap on a source image, before any decode."
  def max_side, do: @max_side

  @doc """
  Refuses an opened (not yet decoded) image whose declared dimensions exceed
  the caps. Returns `:ok` or `{:error, :image_too_large}`.
  """
  @spec validate(Vix.Vips.Image.t()) :: :ok | {:error, :image_too_large}
  def validate(image) do
    {w, h, _bands} = Image.shape(image)

    if w > @max_side or h > @max_side or w * h > @max_pixels,
      do: {:error, :image_too_large},
      else: :ok
  end
end
