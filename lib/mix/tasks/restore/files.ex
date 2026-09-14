defmodule Mix.Tasks.Restore.Files do
  @moduledoc """
  Restores uploaded files from a `.tar.gz` backup archive.

      mix restore.files <backup_file>

  ## Arguments

    * `backup_file` — path to the `.tar.gz` archive

  Extracts the archive into the parent of the real uploads directory (symlinks
  resolved), restoring the `uploads/` tree. See `Baudrate.Backup.restore_files/1`.

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

    Helper.load_config!()
    Mix.shell().info("Restoring uploaded files from #{backup_file}...")
    Mix.shell().info("WARNING: This will overwrite existing uploaded files.")

    backup_file
    |> Baudrate.Backup.restore_files()
    |> Helper.report!("Files restored to")
  end
end
