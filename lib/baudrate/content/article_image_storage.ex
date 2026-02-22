defmodule Baudrate.Content.ArticleImageStorage do
  @moduledoc """
  Processes, stores, and manages article images.

  ## Security

    * Magic bytes validation rejects disguised files
    * Images are decoded to raw pixels and re-encoded as WebP,
      destroying polyglot files and embedded exploits
    * All EXIF/metadata is stripped (`strip_metadata: true`)
    * Images are downscaled to max 1024px on the longest side
    * File paths use server-generated random hex IDs; no user input in paths
    * Uses `image` library (libvips NIF) — no CLI shelling, no command injection surface
  """

  @upload_dir Path.join([:code.priv_dir(:baudrate), "static", "uploads", "article_images"])
  @max_dimension 1024

  @magic_bytes [
    {<<0xFF, 0xD8, 0xFF>>, :jpeg},
    {<<0x89, 0x50, 0x4E, 0x47>>, :png},
    {<<0x47, 0x49, 0x46, 0x38>>, :gif}
  ]

  @doc """
  Processes an uploaded image file and stores it as WebP on disk.

  Validates magic bytes, auto-rotates, downscales to max #{@max_dimension}px
  on the longest side (aspect-preserving), re-encodes as WebP with metadata
  stripped.

  Returns `{:ok, %{filename, storage_path, width, height}}` or `{:error, reason}`.
  """
  def process_upload(upload_path) do
    with :ok <- validate_magic_bytes(upload_path),
         {:ok, image} <- Image.open(upload_path, access: :random),
         {:ok, {image, _meta}} <- Image.autorotate(image) do
      {w, h, _bands} = Image.shape(image)

      image =
        if max(w, h) > @max_dimension do
          Image.thumbnail!(image, @max_dimension)
        else
          image
        end

      filename = generate_filename()
      File.mkdir_p!(@upload_dir)
      dest = Path.join(@upload_dir, filename)

      try do
        Image.write!(image, dest, strip_metadata: true)
        {final_w, final_h, _} = Image.shape(Image.open!(dest, access: :random))

        {:ok,
         %{
           filename: filename,
           storage_path: dest,
           width: final_w,
           height: final_h
         }}
      rescue
        e ->
          File.rm(dest)
          {:error, Exception.message(e)}
      end
    end
  end

  @doc """
  Deletes an article image file from disk.
  """
  def delete_image(%{storage_path: path}) when is_binary(path) do
    if File.exists?(path), do: File.rm!(path)
    :ok
  end

  def delete_image(_), do: :ok

  @doc """
  Returns the URL path for an article image.
  """
  def image_url(filename) when is_binary(filename) do
    "/uploads/article_images/#{filename}"
  end

  @doc """
  Returns the upload directory path.
  """
  def upload_dir, do: @upload_dir

  # --- Private ---

  defp validate_magic_bytes(path) do
    case File.read(path) do
      {:ok, data} when byte_size(data) >= 12 ->
        cond do
          detected_type(data) != nil ->
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

  defp detected_type(data) do
    Enum.find_value(@magic_bytes, fn {magic, type} ->
      if byte_size(data) >= byte_size(magic) and
           binary_part(data, 0, byte_size(magic)) == magic do
        type
      end
    end)
  end

  defp generate_filename do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower) |> Kernel.<>(".webp")
  end
end
