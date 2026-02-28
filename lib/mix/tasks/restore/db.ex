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

    unless File.exists?(backup_file) do
      Mix.raise("Backup file not found: #{backup_file}")
    end

    config = Helper.repo_config()
    {env, pg_args} = Helper.pg_env(config)

    {cmd, cmd_args} =
      cond do
        String.ends_with?(backup_file, ".dump") ->
          {"pg_restore", ["--clean", "--if-exists"] ++ pg_args ++ [backup_file]}

        String.ends_with?(backup_file, ".sql") ->
          {"psql", pg_args ++ ["-f", backup_file]}

        true ->
          Mix.raise(
            "Unrecognized backup format: #{Path.extname(backup_file)}. " <>
              "Expected .dump or .sql"
          )
      end

    Mix.shell().info("Restoring database from #{backup_file}...")
    Mix.shell().info("WARNING: This will overwrite current database contents.")

    case System.cmd(cmd, cmd_args, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Database restored successfully from #{backup_file}")

      {output, code} ->
        Mix.raise("#{cmd} failed (exit code #{code}):\n#{output}")
    end
  end
end
