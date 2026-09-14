defmodule Mix.Tasks.Backup.Files do
  @moduledoc """
  Archives the uploads directory into a `.tar.gz` file.

      mix backup.files [--output-dir DIR]

  ## Options

    * `--output-dir` — output directory (default: `backups/`)

  ## Examples

      mix backup.files
      mix backup.files --output-dir /mnt/backups

  Creates a compressed tarball of the uploads directory (symlinks resolved, so
  an Ansible install archives `shared/uploads`), without `media_cache/`. See
  `Baudrate.Backup.backup_files/1`.
  """

  use Mix.Task

  alias Mix.Tasks.Backup.Helper

  @shortdoc "Archives uploaded files (avatars, images)"

  @switches [output_dir: :string]
  @aliases [o: :output_dir]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    Helper.load_config!()
    dir = Helper.ensure_backup_dir!(opts[:output_dir])

    Mix.shell().info("Backing up uploaded files...")

    dir
    |> Baudrate.Backup.backup_files()
    |> Helper.report!("File backup created")
  end
end
