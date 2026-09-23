defmodule Baudrate.Content.ArticleImageStorage do
  @moduledoc """
  Processes, stores, and manages article images.

  ## Security

    * Magic bytes validation rejects disguised files
    * Images are decoded to raw pixels and re-encoded as WebP,
      destroying polyglot files and embedded exploits
    * All EXIF/metadata is stripped (`strip_metadata: true`)
    * Images smaller than 16x16px are rejected
    * Images are downscaled to max 1024px on the longest side
    * File paths use server-generated random hex IDs; no user input in paths
    * Uses `image` library (libvips NIF) — no CLI shelling, no command injection surface
  """

  require Logger

  @max_dimension 1024
  @min_dimension 16

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

  ## Options

    * `:subdir` — the directory under `priv/static/uploads` to write into,
      `"article_images"` by default. Direct-message images use `"dm_images"`,
      which is never served by path (ADR 0071).
  """
  # sobelow_skip ["Traversal.FileModule"]
  def process_upload(upload_path, opts \\ []) do
    dir = upload_dir(Keyword.get(opts, :subdir, "article_images"))

    with :ok <- validate_magic_bytes(upload_path),
         {:ok, image} <- Image.open(upload_path, access: :random),
         {:ok, {image, _meta}} <- Image.autorotate(image),
         :ok <- validate_min_dimensions(image) do
      {w, h, _bands} = Image.shape(image)

      image =
        if max(w, h) > @max_dimension do
          Image.thumbnail!(image, @max_dimension)
        else
          image
        end

      filename = generate_filename()
      ensure_dir!(dir)
      dest = Path.join(dir, filename)

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
  Deletes an article image file from disk, resolving it from `filename`.

  Not from `storage_path`: that column holds an absolute path into the release
  directory current when the file was uploaded, and the deploy keeps only the
  newest few releases (ADR 0040 records the same defect in retention, and the
  orphan sweeps in `Baudrate.Content.Images` had it too). Any deploy between
  the upload and the delete made this a silent no-op — `File.exists?/1` was
  false, so nothing was removed and nothing was reported, while the row
  naming the file went away.

  Used by article images, comment images and timeline-item reply images; all
  three are written by `process_upload/1` and so live in `article_images`,
  whatever table indexes them.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def delete_image(%{filename: filename}) when is_binary(filename) do
    case Baudrate.DataPortability.Files.image_path("article_images", filename) do
      {:ok, path} ->
        case File.rm(path) do
          :ok ->
            :ok

          {:error, :enoent} ->
            Logger.info("images.file_already_gone: filename=#{filename}")
            :ok

          {:error, reason} ->
            Logger.warning("images.delete_failed: filename=#{filename} reason=#{inspect(reason)}")
            :ok
        end

      :error ->
        Logger.info("images.unresolvable_filename: filename=#{inspect(filename)}")
        :ok
    end
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
  def upload_dir(subdir \\ "article_images")
      when subdir in ["article_images", "dm_images"] do
    Application.app_dir(:baudrate, Path.join(["priv", "static", "uploads", subdir]))
  end

  # --- Private ---

  # sobelow_skip ["Traversal.FileModule"]
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

  defp validate_min_dimensions(image) do
    {w, h, _} = Image.shape(image)

    if w >= @min_dimension and h >= @min_dimension do
      :ok
    else
      {:error, :image_too_small}
    end
  end

  # Direct-message images are private (ADR 0071): their directory is 0700,
  # readable by the application's user alone and not by the web server that
  # serves the rest of uploads/ by path.
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_dir!(dir) do
    File.mkdir_p!(dir)
    if Path.basename(dir) == "dm_images", do: File.chmod!(dir, 0o700)
  end

  defp generate_filename do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower) |> Kernel.<>(".webp")
  end
end
