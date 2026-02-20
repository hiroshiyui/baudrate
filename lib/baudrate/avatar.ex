defmodule Baudrate.Avatar do
  @moduledoc """
  Processes, stores, and manages user avatar images.

  ## Security

    * Magic bytes validation rejects disguised files
    * Images are decoded to raw pixels and re-encoded as WebP,
      destroying polyglot files and embedded exploits
    * All EXIF/metadata is stripped (`strip: true`)
    * File paths use server-generated random hex IDs; no user input in paths
    * Uses `image` library (libvips NIF) — no CLI shelling, no command injection surface
  """

  @avatar_dir Path.join([:code.priv_dir(:baudrate), "static", "uploads", "avatars"])
  @sizes [48, 36]

  @magic_bytes %{
    <<0xFF, 0xD8, 0xFF>> => :jpeg,
    <<0x89, 0x50, 0x4E, 0x47>> => :png,
    # WebP: starts with RIFF....WEBP
    "RIFF" => :webp_prefix
  }

  @doc """
  Processes an uploaded avatar image and saves two sizes (48x48 and 36x36) as WebP.

  `upload_path` is the temporary file path from LiveView's `consume_uploaded_entries`.
  `crop_params` is a map with normalized percentage keys: `"x"`, `"y"`, `"width"`, `"height"`.

  Returns `{:ok, avatar_id}` or `{:error, reason}`.
  """
  def process_upload(upload_path, crop_params) do
    with :ok <- validate_magic_bytes(upload_path),
         {:ok, image} <- Image.open(upload_path, access: :random),
         {:ok, {image, _meta}} <- Image.autorotate(image),
         {:ok, cropped} <- apply_crop(image, crop_params) do
      avatar_id = generate_avatar_id()
      avatar_dir = Path.join(@avatar_dir, avatar_id)
      File.mkdir_p!(avatar_dir)

      try do
        for size <- @sizes do
          dest = Path.join(avatar_dir, "#{size}.webp")
          thumbnail = Image.thumbnail!(cropped, size, crop: :center)
          Image.write!(thumbnail, dest, strip_metadata: true)
        end

        {:ok, avatar_id}
      rescue
        e ->
          File.rm_rf!(avatar_dir)
          {:error, Exception.message(e)}
      end
    end
  end

  @doc """
  Deletes avatar files for the given avatar_id.
  """
  def delete_avatar(nil), do: :ok

  def delete_avatar(avatar_id) when is_binary(avatar_id) do
    dir = Path.join(@avatar_dir, avatar_id)

    if File.dir?(dir) do
      File.rm_rf!(dir)
    end

    :ok
  end

  @doc """
  Returns the URL path for an avatar image.
  """
  def avatar_url(avatar_id, size) when size in @sizes do
    "/uploads/avatars/#{avatar_id}/#{size}.webp"
  end

  @doc """
  Generates a 64-character random hex string for use as avatar_id.
  """
  def generate_avatar_id do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  # --- Private ---

  defp validate_magic_bytes(path) do
    case File.read(path) do
      {:ok, data} when byte_size(data) >= 12 ->
        cond do
          match?({:ok, _}, Map.fetch(@magic_bytes, binary_part(data, 0, 3))) ->
            :ok

          match?({:ok, _}, Map.fetch(@magic_bytes, binary_part(data, 0, 4))) ->
            :ok

          # WebP: RIFF????WEBP
          binary_part(data, 0, 4) == "RIFF" and binary_part(data, 8, 4) == "WEBP" ->
            :ok

          true ->
            {:error, :invalid_image}
        end

      {:ok, _} ->
        {:error, :invalid_image}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_crop(image, %{"x" => x, "y" => y, "width" => w, "height" => h}) do
    {img_width, img_height, _} = Image.shape(image)

    # Convert normalized percentages to pixel values
    crop_x = round(x * img_width) |> max(0) |> min(img_width - 1)
    crop_y = round(y * img_height) |> max(0) |> min(img_height - 1)
    crop_w = round(w * img_width) |> max(1) |> min(img_width - crop_x)
    crop_h = round(h * img_height) |> max(1) |> min(img_height - crop_y)

    Image.crop(image, crop_x, crop_y, crop_w, crop_h)
  end

  defp apply_crop(image, _no_crop) do
    # No crop params — use the whole image, crop to center square
    {img_width, img_height, _} = Image.shape(image)
    side = min(img_width, img_height)
    x = div(img_width - side, 2)
    y = div(img_height - side, 2)

    Image.crop(image, x, y, side, side)
  end
end
