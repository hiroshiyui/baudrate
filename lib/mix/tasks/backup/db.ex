defmodule Mix.Tasks.Backup.Db do
  @moduledoc """
  Backs up the PostgreSQL database using `pg_dump`.

      mix backup.db [--format FORMAT] [--output-dir DIR]

  ## Options

    * `--format` — dump format: `custom` (default) or `sql`
    * `--output-dir` — output directory (default: `backups/`)

  ## Examples

      mix backup.db
      mix backup.db --format sql
      mix backup.db --output-dir /mnt/backups

  The `custom` format produces a `.dump` file (compressed, restorable with
  `pg_restore`). The `sql` format produces a plain `.sql` file (human-readable,
  restorable with `psql`).
  """

  use Mix.Task

  alias Mix.Tasks.Backup.Helper

  @shortdoc "Backs up the PostgreSQL database"

  @switches [format: :string, output_dir: :string]
  @aliases [f: :format, o: :output_dir]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    format = opts[:format] || "custom"

    unless format in ["custom", "sql"] do
      Mix.raise("Invalid format: #{format}. Use \"custom\" or \"sql\".")
    end

    dir = Helper.ensure_backup_dir!(opts[:output_dir])
    config = Helper.repo_config()
    {env, pg_args} = Helper.pg_env(config)

    extension = if format == "custom", do: ".dump", else: ".sql"
    filename = "baudrate_db_#{Helper.timestamp()}#{extension}"
    output_path = Path.join(dir, filename)

    dump_args =
      if format == "custom" do
        ["-Fc", "-f", output_path] ++ pg_args
      else
        ["-f", output_path] ++ pg_args
      end

    Mix.shell().info("Backing up database...")

    case System.cmd("pg_dump", dump_args, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        size = output_path |> File.stat!() |> Map.get(:size) |> Helper.format_size()
        Mix.shell().info("Database backup created: #{output_path} (#{size})")

      {output, code} ->
        Mix.raise("pg_dump failed (exit code #{code}):\n#{output}")
    end
  end
end
