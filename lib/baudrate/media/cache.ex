defmodule Baudrate.Media.Cache do
  @moduledoc """
  Content-addressed local cache of remote images.

  Mirrors `Baudrate.Content.LinkPreview.ImageProxy`: fetch through the
  SSRF-guarded `Federation.HTTPClient`, validate magic bytes, re-encode to WebP
  via libvips with metadata stripped, and store under a SHA-256 of the source
  URL. The remote bytes exist only in memory — the original file is never
  written to disk and never served.

  SVG is deliberately not accepted: it can carry script.

  ## Storage location

  Files live under `priv/static/uploads/media_cache/`. That path is not
  arbitrary — the production systemd unit grants write access only to
  `shared/uploads`, and only that directory is symlinked into each release. The
  filename is a server-computed hex digest, so no user input ever reaches the
  filesystem.

  The test config overrides the directory (`:media_cache_dir`) with one per
  `MIX_TEST_PARTITION`: the cache tests wipe their directory in `setup`, and a
  shared directory let one partition delete a file another had just warmed.

  The bytes are reachable through `BaudrateWeb.MediaController` only; the nginx
  config denies `/uploads/media_cache/` directly so the signature cannot be
  bypassed.

  ## Eviction

  `purge_stale/1` removes entries untouched for the configured TTL, then
  oldest-first until total size is under `:media_cache_max_bytes`. Eviction is
  non-destructive: an evicted image is simply re-fetched on next view.
  """

  require Logger

  alias Baudrate.Federation.HTTPClient

  @max_image_size 5 * 1024 * 1024
  @max_dimension 1600

  @magic_bytes %{
    <<0xFF, 0xD8, 0xFF>> => :jpeg,
    <<0x89, 0x50, 0x4E, 0x47>> => :png,
    <<0x47, 0x49, 0x46>> => :gif
  }

  @doc "Returns the SHA-256 hex digest used as the cache filename for a URL."
  @spec digest(String.t()) :: String.t()
  def digest(url) when is_binary(url) do
    :sha256 |> :crypto.hash(url) |> Base.encode16(case: :lower)
  end

  @doc "Returns `{:ok, absolute_path}` if the URL is already cached, else `:miss`."
  @spec cached_path(String.t()) :: {:ok, Path.t()} | :miss
  def cached_path(url) when is_binary(url) do
    path = path_for(url)
    if File.regular?(path), do: {:ok, path}, else: :miss
  end

  @doc """
  Fetches, validates, re-encodes, and stores a remote image.

  Returns `{:ok, absolute_path}` or `{:error, reason}`.
  """
  @spec fetch_and_store(String.t()) :: {:ok, Path.t()} | {:error, atom()}
  def fetch_and_store(url) when is_binary(url) do
    with :ok <- HTTPClient.validate_url(url),
         {:ok, %{body: body}} <- fetch(url),
         :ok <- validate_size(body),
         :ok <- validate_magic_bytes(body),
         {:ok, path} <- reencode_and_store(body, url) do
      {:ok, path}
    else
      {:error, reason} ->
        Logger.warning(
          "media.cache_fetch_failed: url=#{String.slice(url, 0, 200)} reason=#{inspect(reason)}"
        )

        {:error, normalize_reason(reason)}
    end
  end

  @doc """
  Marks a cache entry as recently served.

  Eviction is mtime-based, so touching on read approximates a least-recently-used
  policy without a database row per image.
  """
  @spec touch(Path.t()) :: :ok
  def touch(path) do
    _ = File.touch(path)
    :ok
  end

  @doc """
  Deletes entries older than `ttl_days`, then oldest-first until the cache fits
  within `max_bytes`. Returns the number of files removed.
  """
  @spec purge_stale(non_neg_integer() | nil, non_neg_integer() | nil) :: non_neg_integer()
  # sobelow_skip ["Traversal.FileModule"]
  def purge_stale(ttl_days \\ nil, max_bytes \\ nil) do
    ttl_days = ttl_days || config(:media_cache_ttl_days, 30)
    max_bytes = max_bytes || config(:media_cache_max_bytes, 2 * 1024 * 1024 * 1024)

    entries = entries()
    cutoff = System.os_time(:second) - ttl_days * 86_400

    {expired, fresh} = Enum.split_with(entries, &(&1.mtime < cutoff))
    Enum.each(expired, &File.rm(&1.path))

    over_limit = evict_to_size(fresh, max_bytes)

    length(expired) + over_limit
  end

  @doc "Total size in bytes of the cache directory."
  @spec disk_usage() :: non_neg_integer()
  def disk_usage do
    entries() |> Enum.reduce(0, &(&1.size + &2))
  end

  @doc false
  def cache_dir do
    config(
      :media_cache_dir,
      Application.app_dir(:baudrate, Path.join(["priv", "static", "uploads", "media_cache"]))
    )
  end

  # --- Private ---

  defp path_for(url), do: Path.join(cache_dir(), digest(url) <> ".webp")

  defp fetch(url) do
    HTTPClient.get_html(url, headers: [{"accept", "image/*"}], max_size: @max_image_size)
  end

  defp validate_size(body) when byte_size(body) > @max_image_size, do: {:error, :image_too_large}
  defp validate_size(_body), do: :ok

  defp validate_magic_bytes(body) when byte_size(body) < 12, do: {:error, :invalid_image}

  defp validate_magic_bytes(body) do
    cond do
      Map.has_key?(@magic_bytes, binary_part(body, 0, 3)) -> :ok
      Map.has_key?(@magic_bytes, binary_part(body, 0, 4)) -> :ok
      webp?(body) -> :ok
      true -> {:error, :invalid_image}
    end
  end

  defp webp?(body) do
    binary_part(body, 0, 4) == "RIFF" and binary_part(body, 8, 4) == "WEBP"
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp reencode_and_store(body, url) do
    dest = path_for(url)
    File.mkdir_p!(Path.dirname(dest))

    # Write to a unique temp name and rename into place, so two concurrent
    # fetches of the same URL cannot produce a torn file. The `.webp` suffix is
    # load-bearing — libvips picks the encoder from the file extension.
    tmp = "#{dest}.#{:erlang.unique_integer([:positive])}.tmp.webp"

    with {:ok, image} <- Image.from_binary(body),
         {:ok, resized} <- resize_to_fit(image),
         {:ok, _written} <- Image.write(resized, tmp, strip_metadata: true),
         :ok <- File.rename(tmp, dest) do
      {:ok, dest}
    else
      error ->
        File.rm(tmp)
        if match?({:error, _}, error), do: error, else: {:error, :reencode_failed}
    end
  rescue
    e ->
      Logger.warning("media.cache_reencode_failed: reason=#{Exception.message(e)}")
      {:error, :reencode_failed}
  end

  defp resize_to_fit(image) do
    {width, height, _} = Image.shape(image)

    if width <= @max_dimension and height <= @max_dimension do
      {:ok, image}
    else
      if width >= height do
        {:ok, Image.thumbnail!(image, @max_dimension)}
      else
        {:ok, Image.thumbnail!(image, "x#{@max_dimension}")}
      end
    end
  end

  defp entries do
    dir = cache_dir()

    case File.ls(dir) do
      {:ok, names} ->
        names
        # Never evict (or count) a fetch that is still being written.
        |> Enum.reject(&String.contains?(&1, ".tmp."))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(fn path ->
          case File.stat(path, time: :posix) do
            {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
              [%{path: path, mtime: mtime, size: size}]

            _ ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp evict_to_size(entries, max_bytes) do
    total = Enum.reduce(entries, 0, &(&1.size + &2))

    if total <= max_bytes do
      0
    else
      entries
      |> Enum.sort_by(& &1.mtime)
      |> Enum.reduce_while({total, 0}, fn entry, {remaining, removed} ->
        if remaining <= max_bytes do
          {:halt, {remaining, removed}}
        else
          File.rm(entry.path)
          {:cont, {remaining - entry.size, removed + 1}}
        end
      end)
      |> elem(1)
    end
  end

  # HTTPClient surfaces tuples like `{:http_error, 404, body}`; the caller only
  # needs an atom to decide between "negative-cache this" and "retry later".
  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason({:http_error, _status, _body}), do: :http_error
  defp normalize_reason({:request_failed, _}), do: :request_failed
  defp normalize_reason(_), do: :fetch_failed

  defp config(key, default) do
    Application.get_env(:baudrate, Baudrate.Media, [])
    |> Keyword.get(key, default)
  end
end
