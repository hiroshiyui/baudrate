defmodule Mix.Tasks.Restore.Files do
  @moduledoc """
  Restores uploaded files from a `.tar.gz` backup archive.

      mix restore.files <backup_file>

  ## Arguments

    * `backup_file` — path to the `.tar.gz` archive

  Extracts the archive into `priv/static/`, restoring the `uploads/` directory
  structure (avatars and article images).

  ## Examples

      mix restore.files backups/baudrate_files_20260228_120000.tar.gz

  **Warning:** This overwrites existing uploaded files.
  """

  use Mix.Task

  alias Mix.Tasks.Backup.Helper

  @shortdoc "Restores uploaded files from a backup archive"

  @impl Mix.Task
  def run(args) do
    {_opts, rest, _invalid} = OptionParser.parse(args, switches: [])

    backup_file =
      case rest do
        [file | _] -> file
        [] -> Mix.raise("Usage: mix restore.files <backup_file>")
      end

    unless File.exists?(backup_file) do
      Mix.raise("Backup file not found: #{backup_file}")
    end

    unless String.ends_with?(backup_file, ".tar.gz") do
      Mix.raise("Expected a .tar.gz file, got: #{backup_file}")
    end

    # Extract to the parent of the uploads dir (priv/static/)
    uploads_dir = Helper.uploads_dir()
    extract_dir = Path.dirname(uploads_dir)

    File.mkdir_p!(extract_dir)

    Mix.shell().info("Restoring uploaded files from #{backup_file}...")
    Mix.shell().info("WARNING: This will overwrite existing uploaded files.")

    tar_args = ["-xzf", backup_file, "-C", extract_dir]

    case System.cmd("tar", tar_args, stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Files restored successfully to #{uploads_dir}")

      {output, code} ->
        Mix.raise("tar failed (exit code #{code}):\n#{output}")
    end
  end
end
