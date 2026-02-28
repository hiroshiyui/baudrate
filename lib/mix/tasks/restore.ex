defmodule Mix.Tasks.Restore do
  @moduledoc """
  Restores both the database and uploaded files from backup files.

      mix restore <db_backup> <files_backup>

  ## Arguments

    * `db_backup` — path to the database backup file (`.dump` or `.sql`)
    * `files_backup` — path to the files backup archive (`.tar.gz`)

  ## Examples

      mix restore backups/baudrate_db_20260228_120000.dump backups/baudrate_files_20260228_120000.tar.gz

  **Warning:** This overwrites the current database and uploaded files.
  """

  use Mix.Task

  @shortdoc "Restores database and uploaded files from backups"

  @impl Mix.Task
  def run(args) do
    {_opts, rest, _invalid} = OptionParser.parse(args, switches: [])

    case rest do
      [db_backup, files_backup] ->
        Mix.Tasks.Restore.Db.run([db_backup])
        Mix.Tasks.Restore.Files.run([files_backup])
        Mix.shell().info("Full restore complete.")

      _ ->
        Mix.raise("Usage: mix restore <db_backup> <files_backup>")
    end
  end
end
