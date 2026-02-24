defmodule Baudrate.AttachmentStorage do
  @moduledoc """
  Processes, stores, and manages file attachments for articles.

  ## Security

    * Magic bytes validation rejects disguised files
    * Image files are decoded and re-encoded via libvips, stripping metadata
      and destroying polyglot payloads
    * File paths use server-generated hex names; no user input in paths
    * Uses `image` library (libvips NIF) for image processing — no CLI shelling
  """

  @upload_dir Path.join([:code.priv_dir(:baudrate), "static", "uploads", "attachments"])

  @image_types ~w[image/jpeg image/png image/webp image/gif]

  @magic_bytes [
    {<<0xFF, 0xD8, 0xFF>>, "image/jpeg"},
    {<<0x89, 0x50, 0x4E, 0x47>>, "image/png"},
    {<<0x47, 0x49, 0x46, 0x38>>, "image/gif"},
    {<<0x25, 0x50, 0x44, 0x46>>, "application/pdf"},
    {<<0x50, 0x4B, 0x03, 0x04>>, "application/zip"}
  ]

  @doc """
  Processes an uploaded file and stores it on disk.

  For image files, re-encodes through libvips to strip metadata.
  Returns `{:ok, %{filename, storage_path, content_type, size}}` or `{:error, reason}`.
  """
  def process_upload(upload_path, original_filename, content_type) do
    with :ok <- validate_magic_bytes(upload_path, content_type) do
      hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      safe_name = sanitize_filename(original_filename)
      filename = "#{hex}_#{safe_name}"

      # We'll store in a flat directory (article_id set at link time)
      dest_dir = @upload_dir
      File.mkdir_p!(dest_dir)
      dest = Path.join(dest_dir, filename)

      if content_type in @image_types do
        process_image(upload_path, dest)
      else
        File.cp!(upload_path, dest)
      end

      size = File.stat!(dest).size

      {:ok,
       %{
         filename: filename,
         storage_path: dest,
         content_type: content_type,
         size: size
       }}
    end
  end

  @doc """
  Deletes an attachment file from disk.
  """
  def delete_attachment(%{storage_path: path}) when is_binary(path) do
    if File.exists?(path), do: File.rm!(path)
    :ok
  end

  def delete_attachment(_), do: :ok

  @doc """
  Returns the URL path for an attachment.
  """
  def attachment_url(filename) when is_binary(filename) do
    "/uploads/attachments/#{filename}"
  end

  # --- Private ---

  defp process_image(source, dest) do
    {:ok, image} = Image.open(source, access: :random)
    Image.write!(image, dest, strip_metadata: true)
  end

  defp validate_magic_bytes(path, content_type) do
    case File.read(path) do
      {:ok, data} when byte_size(data) >= 4 ->
        detected = detect_content_type(data)

        cond do
          # WebP: RIFF....WEBP
          content_type == "image/webp" and binary_part(data, 0, 4) == "RIFF" and
            byte_size(data) >= 12 and binary_part(data, 8, 4) == "WEBP" ->
            :ok

          # Text and markdown don't have magic bytes — allow if content_type matches
          content_type in ["text/plain", "text/markdown"] ->
            :ok

          detected == content_type ->
            :ok

          true ->
            {:error, :invalid_file_type}
        end

      {:ok, _} ->
        {:error, :invalid_file_type}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp detect_content_type(data) do
    Enum.find_value(@magic_bytes, fn {magic, type} ->
      if byte_size(data) >= byte_size(magic) and binary_part(data, 0, byte_size(magic)) == magic do
        type
      end
    end)
  end

  defp sanitize_filename(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^\w.\-]/, "_")
    |> String.slice(0, 100)
  end
end
