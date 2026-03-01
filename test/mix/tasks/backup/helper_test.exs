defmodule Mix.Tasks.Backup.HelperTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Backup.Helper

  describe "timestamp/0" do
    test "returns a string in YYYYMMDD_HHMMSS format" do
      ts = Helper.timestamp()
      assert Regex.match?(~r/^\d{8}_\d{6}$/, ts)
    end

    test "returns a consistent-length string" do
      ts = Helper.timestamp()
      assert String.length(ts) == 15
    end
  end

  describe "ensure_backup_dir!/1" do
    test "creates directory and returns path" do
      dir =
        Path.join(System.tmp_dir!(), "baudrate_test_backup_#{System.unique_integer([:positive])}")

      refute File.exists?(dir)

      result = Helper.ensure_backup_dir!(dir)
      assert result == dir
      assert File.dir?(dir)
    after
      # cleanup
      dir = Path.join(System.tmp_dir!(), "baudrate_test_backup_*")
      for path <- Path.wildcard(dir), do: File.rm_rf!(path)
    end

    test "defaults to 'backups' when nil" do
      result = Helper.ensure_backup_dir!(nil)
      assert result == "backups"
      assert File.dir?("backups")
    end
  end

  describe "format_size/1" do
    test "formats bytes" do
      assert Helper.format_size(0) == "0 B"
      assert Helper.format_size(512) == "512 B"
      assert Helper.format_size(1023) == "1023 B"
    end

    test "formats kilobytes" do
      assert Helper.format_size(1024) == "1.0 KB"
      assert Helper.format_size(1536) == "1.5 KB"
    end

    test "formats megabytes" do
      assert Helper.format_size(1024 * 1024) == "1.0 MB"
      assert Helper.format_size(5 * 1024 * 1024) == "5.0 MB"
    end

    test "formats gigabytes" do
      assert Helper.format_size(1024 * 1024 * 1024) == "1.0 GB"
      assert Helper.format_size(2 * 1024 * 1024 * 1024) == "2.0 GB"
    end
  end

  describe "pg_env/1" do
    test "builds env and args from direct config" do
      config = [
        username: "testuser",
        password: "testpass",
        hostname: "localhost",
        port: 5432,
        database: "testdb"
      ]

      {env, args} = Helper.pg_env(config)

      assert {"PGPASSWORD", "testpass"} in env
      assert "-U" in args
      assert "testuser" in args
      assert "-h" in args
      assert "localhost" in args
      assert "-p" in args
      assert "5432" in args
      assert "-d" in args
      assert "testdb" in args
    end

    test "builds env and args from DATABASE_URL" do
      config = [url: "postgres://myuser:mypass@dbhost:5433/mydb"]

      {env, args} = Helper.pg_env(config)

      assert {"PGPASSWORD", "mypass"} in env
      assert "-U" in args
      assert "myuser" in args
      assert "-h" in args
      assert "dbhost" in args
      assert "-p" in args
      assert "5433" in args
      assert "-d" in args
      assert "mydb" in args
    end

    test "handles config without password" do
      config = [username: "trustuser", hostname: "localhost", database: "testdb"]

      {env, args} = Helper.pg_env(config)

      refute Enum.any?(env, fn {k, _} -> k == "PGPASSWORD" end)
      assert "-U" in args
    end

    test "defaults hostname to localhost and port to 5432" do
      config = [database: "testdb"]

      {_env, args} = Helper.pg_env(config)

      assert "-h" in args
      assert "localhost" in args
      assert "-p" in args
      assert "5432" in args
    end

    test "handles DATABASE_URL with encoded characters" do
      config = [url: "postgres://user%40name:p%40ss@host:5432/db"]

      {env, args} = Helper.pg_env(config)

      assert {"PGPASSWORD", "p@ss"} in env
      assert "user@name" in args
    end
  end

  describe "repo_config/0" do
    test "returns a keyword list" do
      config = Helper.repo_config()
      assert is_list(config)
    end
  end

  describe "uploads_dir/0" do
    test "returns a path ending in uploads" do
      dir = Helper.uploads_dir()
      assert String.ends_with?(dir, "uploads")
    end
  end
end
