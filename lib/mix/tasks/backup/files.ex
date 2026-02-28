defmodule Mix.Tasks.Backup.Files do
  @moduledoc """
  Archives the uploads directory into a `.tar.gz` file.

      mix backup.files [--output-dir DIR]

  ## Options

    * `--output-dir` — output directory (default: `backups/`)

  ## Examples

      mix backup.files
      mix backup.files --output-dir /mnt/backups

  Creates a compressed tarball of `priv/static/uploads/` containing avatars
  and article images.
  """

  use Mix.Task

  alias Mix.Tasks.Backup.Helper

  @shortdoc "Archives uploaded files (avatars, images)"

  @switches [output_dir: :string]
  @aliases [o: :output_dir]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    uploads_dir = Helper.uploads_dir()

    unless File.dir?(uploads_dir) do
      Mix.raise("Uploads directory not found: #{uploads_dir}")
    end

    dir = Helper.ensure_backup_dir!(opts[:output_dir])
    filename = "baudrate_files_#{Helper.timestamp()}.tar.gz"
    output_path = Path.join(dir, filename)

    # Archive relative to priv/static/ so the tarball contains uploads/
    base_dir = Path.dirname(uploads_dir)

    tar_args = ["-czf", output_path, "-C", base_dir, "uploads"]

    Mix.shell().info("Backing up uploaded files...")

    case System.cmd("tar", tar_args, stderr_to_stdout: true) do
      {_output, 0} ->
        size = output_path |> File.stat!() |> Map.get(:size) |> Helper.format_size()
        Mix.shell().info("File backup created: #{output_path} (#{size})")

      {output, code} ->
        Mix.raise("tar failed (exit code #{code}):\n#{output}")
    end
  end
end
