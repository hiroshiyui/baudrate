defmodule Mix.Tasks.Backup do
  @moduledoc """
  Backs up both the database and uploaded files.

      mix backup [--format FORMAT] [--output-dir DIR]

  Runs `mix backup.db` followed by `mix backup.files`, forwarding all options.

  ## Options

    * `--format` — database dump format: `custom` (default) or `sql`
    * `--output-dir` — output directory (default: `backups/`)

  ## Examples

      mix backup
      mix backup --format sql --output-dir /mnt/backups
  """

  use Mix.Task

  @shortdoc "Backs up database and uploaded files"

  @impl Mix.Task
  def run(args) do
    Mix.Tasks.Backup.Db.run(args)
    Mix.Tasks.Backup.Files.run(args)
    Mix.shell().info("Full backup complete.")
  end
end
