defmodule Mix.Tasks.Backup.Helper do
  @moduledoc """
  Shared utilities for the backup and restore Mix tasks. The backup logic
  itself lives in `Baudrate.Backup`, so an OTP release can run it too
  (`Baudrate.Release.backup/2`).
  """

  @default_backup_dir "backups"

  @doc "Returns a timestamp string in `YYYYMMDD_HHMMSS` format."
  @spec timestamp() :: String.t()
  defdelegate timestamp, to: Baudrate.Backup

  @doc "Returns a human-readable file size string."
  @spec format_size(non_neg_integer()) :: String.t()
  defdelegate format_size(bytes), to: Baudrate.Backup

  @doc "PostgreSQL CLI environment and arguments. See `Baudrate.Backup.pg_env/1`."
  @spec pg_env(keyword()) :: {[{String.t(), String.t()}], [String.t()]}
  defdelegate pg_env(config), to: Baudrate.Backup

  @doc """
  Ensures the backup directory exists, creating it if necessary.
  Returns the directory path.
  """
  @spec ensure_backup_dir!(String.t() | nil) :: String.t()
  def ensure_backup_dir!(nil), do: ensure_backup_dir!(@default_backup_dir)

  def ensure_backup_dir!(dir) do
    File.mkdir_p!(dir)
    dir
  end

  @doc "Loads the application configuration so `Baudrate.Backup` can read the Repo config."
  @spec load_config!() :: :ok
  def load_config! do
    unless Application.spec(:baudrate) do
      Mix.Task.run("app.config")
    end

    :ok
  end

  @doc "Prints the created file and its size, or raises with the error."
  @spec report!({:ok, String.t()} | {:error, String.t()}, String.t()) :: String.t()
  def report!({:ok, path}, label) do
    size =
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} -> " (#{format_size(size)})"
        _ -> ""
      end

    Mix.shell().info("#{label}: #{path}#{size}")
    path
  end

  def report!({:error, message}, _label), do: Mix.raise(message)
end
