defmodule Baudrate.Backup do
  @moduledoc """
  Database and uploads backup and restore, usable from both an OTP release
  (`Baudrate.Release.backup/2`, `restore/2`) and Mix (`mix backup`,
  `mix restore`).

  Mix tasks are not part of a release, so the logic lives here, compiled into
  the application. Before v1.18.2 it lived only in the Mix tasks, which on an
  Ansible install resolved the uploads directory inside a build tree instead
  of `shared/uploads`, and so archived an almost empty directory without
  error.

  ## Files archive

  The uploads directory is resolved through every symlink first (the Ansible
  deploy links each release's `priv/static/uploads` to `shared/uploads`), then
  archived as `uploads/…` relative to its parent. `media_cache/` is excluded:
  it only holds re-encoded copies of remote images, which are fetched again on
  demand. Restoring extracts into the same parent, so the files land back in
  the real uploads directory.

  All functions return `{:ok, path}` or `{:error, message}`; callers decide
  how to report.
  """

  alias Baudrate.DataPortability.Files

  @formats ~w(custom sql)

  @doc """
  Writes a database dump and an uploads archive into `output_dir`.

  Options: `:format` — `"custom"` (default, for `pg_restore`) or `"sql"`.
  """
  @spec backup(String.t(), keyword()) ::
          {:ok, %{db: String.t(), files: String.t()}} | {:error, String.t()}
  def backup(output_dir, opts \\ []) do
    with {:ok, db} <- backup_db(output_dir, Keyword.get(opts, :format, "custom")),
         {:ok, files} <- backup_files(output_dir) do
      {:ok, %{db: db, files: files}}
    end
  end

  @doc "Dumps the database with `pg_dump` into `output_dir`."
  @spec backup_db(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def backup_db(output_dir, format \\ "custom")

  def backup_db(output_dir, format) when format in @formats do
    File.mkdir_p!(output_dir)
    {env, pg_args} = pg_env(repo_config())
    extension = if format == "custom", do: ".dump", else: ".sql"
    output_path = Path.join(output_dir, "baudrate_db_#{timestamp()}#{extension}")
    format_args = if format == "custom", do: ["-Fc"], else: []

    run("pg_dump", format_args ++ ["-f", output_path] ++ pg_args, env, output_path)
  end

  def backup_db(_output_dir, format),
    do: {:error, "Invalid format: #{format}. Use \"custom\" or \"sql\"."}

  @doc "Archives the uploads directory (without `media_cache/`) into `output_dir`."
  @spec backup_files(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def backup_files(output_dir) do
    with {:ok, uploads} <- uploads_dir() do
      File.mkdir_p!(output_dir)
      output_path = Path.join(output_dir, "baudrate_files_#{timestamp()}.tar.gz")
      name = Path.basename(uploads)

      args = [
        "-czf",
        output_path,
        "-C",
        Path.dirname(uploads),
        "--exclude=#{name}/media_cache",
        name
      ]

      run("tar", args, [], output_path)
    end
  end

  @doc """
  Restores the database from a `.dump` (`pg_restore --clean`) or `.sql`
  (`psql`) file. Overwrites the current database contents.
  """
  @spec restore_db(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def restore_db(backup_file) do
    {env, pg_args} = pg_env(repo_config())

    cond do
      not File.exists?(backup_file) ->
        {:error, "Backup file not found: #{backup_file}"}

      String.ends_with?(backup_file, ".dump") ->
        run(
          "pg_restore",
          ["--clean", "--if-exists"] ++ pg_args ++ [backup_file],
          env,
          backup_file
        )

      String.ends_with?(backup_file, ".sql") ->
        run("psql", pg_args ++ ["-f", backup_file], env, backup_file)

      true ->
        {:error,
         "Unrecognized backup format: #{Path.extname(backup_file)}. Expected .dump or .sql"}
    end
  end

  @doc """
  Extracts an uploads archive back into the real uploads directory's parent.
  Overwrites existing files with the same names.
  """
  @spec restore_files(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def restore_files(backup_file) do
    cond do
      not File.exists?(backup_file) ->
        {:error, "Backup file not found: #{backup_file}"}

      not String.ends_with?(backup_file, ".tar.gz") ->
        {:error, "Expected a .tar.gz file, got: #{backup_file}"}

      true ->
        with {:ok, uploads} <- uploads_dir() do
          run("tar", ["-xzf", backup_file, "-C", Path.dirname(uploads)], [], uploads)
        end
    end
  end

  @doc """
  The real uploads directory, with every symlink resolved.

  Uses the configured `:data_export_uploads_root` if set, otherwise the
  application's `priv/static/uploads`.
  """
  @spec uploads_dir() :: {:ok, String.t()} | {:error, String.t()}
  def uploads_dir do
    configured = Files.uploads_root()

    case Files.realpath(configured) do
      {:ok, real} ->
        if File.dir?(real), do: {:ok, real}, else: {:error, "Not a directory: #{real}"}

      :error ->
        {:error, "Uploads directory not found: #{configured}"}
    end
  end

  @doc "A local-time `YYYYMMDD_HHMMSS` timestamp for backup file names."
  @spec timestamp() :: String.t()
  def timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.local_time()

    :io_lib.format("~4..0B~2..0B~2..0B_~2..0B~2..0B~2..0B", [
      year,
      month,
      day,
      hour,
      minute,
      second
    ])
    |> IO.iodata_to_binary()
  end

  @doc "A human-readable file size."
  @spec format_size(non_neg_integer()) :: String.t()
  def format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  def format_size(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  def format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"

  @doc """
  PostgreSQL CLI environment and arguments from a Repo configuration.

  Supports both direct keys (`username`, `password`, `hostname`, `database`,
  `port`) and a `:url`. Returns `{env, args}`; the password is passed only in
  `PGPASSWORD`, never on the command line.
  """
  @spec pg_env(keyword()) :: {[{String.t(), String.t()}], [String.t()]}
  def pg_env(config) do
    parsed = parse_database_url(config[:url])

    password = parsed[:password] || config[:password]
    username = parsed[:username] || config[:username]
    hostname = parsed[:hostname] || config[:hostname] || "localhost"
    port = parsed[:port] || config[:port] || 5432
    database = parsed[:database] || config[:database]

    env = if password, do: [{"PGPASSWORD", to_string(password)}], else: []

    args =
      if(username, do: ["-U", to_string(username)], else: []) ++
        ["-h", to_string(hostname), "-p", to_string(port)] ++
        if(database, do: ["-d", to_string(database)], else: [])

    {env, args}
  end

  defp repo_config, do: Application.get_env(:baudrate, Baudrate.Repo, [])

  defp run(cmd, args, env, result_path) do
    case System.find_executable(cmd) do
      nil ->
        {:error, "#{cmd} not found in PATH"}

      _ ->
        case System.cmd(cmd, args, env: env, stderr_to_stdout: true) do
          {_output, 0} -> {:ok, result_path}
          {output, code} -> {:error, "#{cmd} failed (exit code #{code}):\n#{output}"}
        end
    end
  end

  defp parse_database_url(nil), do: []

  defp parse_database_url(url) do
    uri = URI.parse(url)

    userinfo =
      case uri.userinfo && String.split(uri.userinfo, ":", parts: 2) do
        [username, password] -> [username: URI.decode(username), password: URI.decode(password)]
        [username] -> [username: URI.decode(username)]
        nil -> []
      end

    database = if uri.path, do: String.trim_leading(uri.path, "/")

    (userinfo ++ [hostname: uri.host, port: uri.port, database: database])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end
end
