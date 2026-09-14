defmodule Mix.Tasks.Restore.Db do
  @moduledoc """
  Restores the PostgreSQL database from a backup file.

      mix restore.db <backup_file>

  ## Arguments

    * `backup_file` — path to the backup file (`.dump` or `.sql`)

  The format is detected from the file extension:

    * `.dump` — restored with `pg_restore --clean --if-exists`
    * `.sql` — restored with `psql`

  ## Examples

      mix restore.db backups/baudrate_db_20260228_120000.dump
      mix restore.db backups/baudrate_db_20260228_120000.sql

  **Warning:** This overwrites the current database contents.
  """

  use Mix.Task

  alias Mix.Tasks.Backup.Helper

  @shortdoc "Restores PostgreSQL database from a backup file"

  @impl Mix.Task
  def run(args) do
    {_opts, rest, _invalid} = OptionParser.parse(args, switches: [])

    backup_file =
      case rest do
        [file | _] -> file
        [] -> Mix.raise("Usage: mix restore.db <backup_file>")
      end

    Helper.load_config!()
    Mix.shell().info("Restoring database from #{backup_file}...")
    Mix.shell().info("WARNING: This will overwrite current database contents.")

    backup_file
    |> Baudrate.Backup.restore_db()
    |> Helper.report!("Database restored from")
  end
end
