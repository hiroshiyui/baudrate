defmodule Baudrate.Content.LinkPreview.ImageProxy do
  @moduledoc """
  Fetches, validates, and re-encodes OG images to WebP.

  Security pipeline:
    1. Fetch via SSRF-safe `HTTPClient` (5 MB cap)
    2. Validate magic bytes (JPEG/PNG/GIF/WebP only)
    3. Re-encode to WebP via libvips (strips EXIF, max 1200x630)
    4. Store locally — remote image never saved to disk raw

  The original remote image exists only in memory during processing.
  """

  require Logger

  alias Baudrate.Federation.HTTPClient

  @max_image_size 5 * 1024 * 1024
  @max_width 1200
  @max_height 630

  @magic_bytes %{
    <<0xFF, 0xD8, 0xFF>> => :jpeg,
    <<0x89, 0x50, 0x4E, 0x47>> => :png,
    <<0x47, 0x49, 0x46>> => :gif
  }

  @doc """
  Fetches an image URL, re-encodes to WebP, and stores locally.

  Returns `{:ok, serving_path}` or `{:error, reason}`.
  """
  @spec proxy_image(String.t(), binary()) :: {:ok, String.t()} | {:error, atom()}
  def proxy_image(image_url, url_hash) when is_binary(image_url) and is_binary(url_hash) do
    with :ok <- HTTPClient.validate_url(image_url),
         {:ok, %{body: body}} <- fetch_image(image_url),
         :ok <- validate_size(body),
         :ok <- validate_magic_bytes(body),
         {:ok, serving_path} <- reencode_and_store(body, url_hash) do
      {:ok, serving_path}
    else
      {:error, reason} ->
        Logger.warning(
          "link_preview.image_proxy_failed: url=#{image_url} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Deletes a cached preview image from disk.
  """
  def delete_image(nil), do: :ok

  def delete_image(image_path) when is_binary(image_path) do
    abs_path = abs_path(image_path)

    case File.rm(abs_path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("link_preview.image_delete_failed: path=#{image_path} reason=#{reason}")
        {:error, reason}
    end
  end

  defp fetch_image(url) do
    HTTPClient.get_html(url, headers: [{"accept", "image/*"}], max_size: @max_image_size)
  end

  defp validate_size(body) when byte_size(body) > @max_image_size, do: {:error, :image_too_large}
  defp validate_size(_body), do: :ok

  defp validate_magic_bytes(body) when byte_size(body) < 12, do: {:error, :invalid_image}

  defp validate_magic_bytes(body) do
    cond do
      match_magic?(body, 3) -> :ok
      match_magic?(body, 4) -> :ok
      webp?(body) -> :ok
      true -> {:error, :invalid_image}
    end
  end

  defp match_magic?(body, len) do
    prefix = binary_part(body, 0, len)
    Map.has_key?(@magic_bytes, prefix)
  end

  defp webp?(body) do
    binary_part(body, 0, 4) == "RIFF" and
      byte_size(body) >= 12 and
      binary_part(body, 8, 4) == "WEBP"
  end

  defp reencode_and_store(body, url_hash) do
    hash_hex = Base.encode16(url_hash, case: :lower)
    serving_path = "/uploads/link_preview_images/#{hash_hex}.webp"
    abs = abs_path(serving_path)

    File.mkdir_p!(Path.dirname(abs))

    with {:ok, image} <- Image.from_binary(body),
         {:ok, resized} <- resize_to_fit(image),
         {:ok, _written} <- Image.write(resized, abs, strip_metadata: true) do
      {:ok, serving_path}
    end
  rescue
    e ->
      Logger.warning("link_preview.image_reencode_failed: reason=#{Exception.message(e)}")
      {:error, :reencode_failed}
  end

  defp resize_to_fit(image) do
    {width, height, _} = Image.shape(image)

    cond do
      width <= @max_width and height <= @max_height ->
        {:ok, image}

      width / height > @max_width / @max_height ->
        {:ok, Image.thumbnail!(image, @max_width)}

      true ->
        {:ok, Image.thumbnail!(image, "x#{@max_height}")}
    end
  end

  defp abs_path(serving_path) do
    Application.app_dir(:baudrate, Path.join(["priv", "static", serving_path]))
  end
end
