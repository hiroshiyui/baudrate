defmodule Baudrate.DataPortability.Files do
  @moduledoc """
  Confines the files a data export may read to the uploads directory
  (ADR 0023 §15).

  Paths come from the database, and a tampered row must not turn the export
  into an arbitrary file read (e.g. `env/baudrate.env`). So this module never
  trusts a stored path:

    * **The path is rebuilt, not taken from the row.** `storage_path` is
      ignored. It is absolute, points into a release directory that deploys
      delete, and is attacker-shaped if the row was tampered with. Paths are
      rebuilt as `<uploads>/<subdir>/<filename>`, and `filename` must match a
      strict pattern (64 lowercase hex characters plus `.webp`), which rules
      out separators and `..`.
    * **Symlinks are resolved.** In production `priv/static/uploads` is a
      symlink to `shared/uploads`, so the root is resolved to its real path
      once. Every component under the root must be a real directory (not a
      symlink), and the file itself must be a regular file, not a symlink.

  Anything that fails a check is skipped. The caller logs it; it is never
  read.
  """

  require Logger

  @hex_webp ~r/\A[0-9a-f]{64}\.webp\z/
  @hex_id ~r/\A[0-9a-f]{64}\z/
  @max_symlink_depth 40

  @doc "The uploads root as configured (may itself be a symlink)."
  @spec uploads_root() :: String.t()
  def uploads_root do
    Application.get_env(:baudrate, :data_export_uploads_root) ||
      Application.app_dir(:baudrate, Path.join(["priv", "static", "uploads"]))
  end

  @doc """
  Resolves an uploaded image `filename` under `subdir` (e.g.
  `"article_images"`). Returns `{:ok, absolute_path}` or `:error`.
  """
  @spec image_path(String.t(), String.t() | nil) :: {:ok, String.t()} | :error
  def image_path(subdir, filename) when is_binary(filename) do
    if Regex.match?(@hex_webp, filename), do: confined([subdir, filename]), else: :error
  end

  def image_path(_subdir, _filename), do: :error

  @doc """
  Resolves one avatar rendition (`size` in pixels) for `avatar_id`.
  Returns `{:ok, absolute_path}` or `:error`.
  """
  @spec avatar_path(String.t() | nil, pos_integer()) :: {:ok, String.t()} | :error
  def avatar_path(avatar_id, size) when is_binary(avatar_id) and is_integer(size) do
    if Regex.match?(@hex_id, avatar_id),
      do: confined(["avatars", avatar_id, "#{size}.webp"]),
      else: :error
  end

  def avatar_path(_avatar_id, _size), do: :error

  # Every component below the resolved root must be a real directory, and the
  # last one a regular file. `File.lstat/1` does not follow symlinks, so a
  # symlinked component is rejected rather than followed out of the root.
  defp confined(components) do
    with {:ok, root} <- realpath(uploads_root()),
         {:ok, path} <- walk(root, components) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  defp walk(dir, [file]) do
    path = Path.join(dir, file)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, path}
      _ -> :error
    end
  end

  defp walk(dir, [component | rest]) do
    path = Path.join(dir, component)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, rest)
      _ -> :error
    end
  end

  @doc false
  # Resolves every symlink in `path`. Returns `{:ok, real_path}` or `:error`.
  def realpath(path), do: resolve(Path.split(Path.expand(path)), "/", 0)

  defp resolve(_components, _acc, depth) when depth > @max_symlink_depth, do: :error
  defp resolve([], acc, _depth), do: {:ok, acc}
  defp resolve(["/" | rest], _acc, depth), do: resolve(rest, "/", depth)

  defp resolve([component | rest], acc, depth) do
    candidate = Path.join(acc, component)

    case :file.read_link_all(String.to_charlist(candidate)) do
      {:ok, target} ->
        target = List.to_string(target)
        base = if Path.type(target) == :absolute, do: "/", else: acc
        resolve(Path.split(Path.expand(target, base)) ++ rest, "/", depth + 1)

      {:error, :einval} ->
        # Not a symlink.
        if File.exists?(candidate), do: resolve(rest, candidate, depth), else: :error

      {:error, _} ->
        :error
    end
  end
end
