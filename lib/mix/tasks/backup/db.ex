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

    Helper.load_config!()
    dir = Helper.ensure_backup_dir!(opts[:output_dir])

    Mix.shell().info("Backing up database...")

    dir
    |> Baudrate.Backup.backup_db(opts[:format] || "custom")
    |> Helper.report!("Database backup created")
  end
end
