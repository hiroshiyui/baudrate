defmodule Mix.Tasks.Backup.Helper do
  @moduledoc """
  Shared utilities for backup and restore mix tasks.
  """

  @default_backup_dir "backups"

  @doc """
  Returns a timestamp string in `YYYYMMDD_HHMMSS` format.
  """
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

  @doc """
  Ensures the backup directory exists, creating it if necessary.
  Returns the directory path.
  """
  @spec ensure_backup_dir!(String.t() | nil) :: String.t()
  def ensure_backup_dir!(nil), do: ensure_backup_dir!(@default_backup_dir)

  def ensure_backup_dir!(dir) do
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Returns the Ecto Repo configuration as a keyword list.

  Supports both direct config keys (`username`, `password`, `hostname`,
  `database`, `port`) and `DATABASE_URL` via the `:url` key.
  """
  @spec repo_config() :: keyword()
  def repo_config do
    ensure_app_loaded()
    Application.get_env(:baudrate, Baudrate.Repo, [])
  end

  @doc """
  Returns the uploads directory path (`priv/static/uploads`).
  """
  @spec uploads_dir() :: String.t()
  def uploads_dir do
    Path.join([Application.app_dir(:baudrate), "priv", "static", "uploads"])
  rescue
    # In dev/test, app_dir may not work; fall back to project-relative path
    ArgumentError ->
      Path.join(["priv", "static", "uploads"])
  end

  @doc """
  Builds environment variables and common PostgreSQL CLI arguments
  from the Repo configuration.

  Returns `{env_list, args}` where `env_list` is a list of `{"VAR", "val"}`
  tuples and `args` is a list of CLI argument strings.
  """
  @spec pg_env(keyword()) :: {[{String.t(), String.t()}], [String.t()]}
  def pg_env(config) do
    {parsed, env, args} = parse_database_url(config)

    password = parsed[:password] || config[:password]
    username = parsed[:username] || config[:username]
    hostname = parsed[:hostname] || config[:hostname] || "localhost"
    port = parsed[:port] || config[:port] || 5432
    database = parsed[:database] || config[:database]

    env = if password, do: [{"PGPASSWORD", to_string(password)} | env], else: env

    args =
      args ++
        if(username, do: ["-U", to_string(username)], else: []) ++
        ["-h", to_string(hostname)] ++
        ["-p", to_string(port)] ++
        if(database, do: ["-d", to_string(database)], else: [])

    {env, args}
  end

  @doc """
  Returns a human-readable file size string.
  """
  @spec format_size(non_neg_integer()) :: String.t()
  def format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  def format_size(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  def format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"

  # Parses DATABASE_URL if present in config[:url].
  # Returns {parsed_fields, extra_env, extra_args}.
  defp parse_database_url(config) do
    case config[:url] do
      nil ->
        {[], [], []}

      url ->
        uri = URI.parse(url)
        userinfo = parse_userinfo(uri.userinfo)
        database = if uri.path, do: String.trim_leading(uri.path, "/")

        parsed =
          [
            username: userinfo[:username],
            password: userinfo[:password],
            hostname: uri.host,
            port: uri.port,
            database: database
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        {parsed, [], []}
    end
  end

  defp parse_userinfo(nil), do: []

  defp parse_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] -> [username: URI.decode(username), password: URI.decode(password)]
      [username] -> [username: URI.decode(username)]
    end
  end

  defp ensure_app_loaded do
    unless Application.spec(:baudrate) do
      Mix.Task.run("app.config")
    end
  end
end
