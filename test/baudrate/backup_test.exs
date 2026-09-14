defmodule Baudrate.BackupTest do
  use ExUnit.Case, async: false

  alias Baudrate.Backup

  setup do
    base = Path.join(System.tmp_dir!(), "baudrate-backup-#{System.unique_integer([:positive])}")
    shared = Path.join(base, "shared/uploads")
    release_static = Path.join(base, "release/priv/static")
    backups = Path.join(base, "backups")

    File.mkdir_p!(Path.join(shared, "avatars/abc"))
    File.mkdir_p!(Path.join(shared, "media_cache"))
    File.mkdir_p!(release_static)
    File.write!(Path.join(shared, "avatars/abc/48.webp"), "avatar")
    File.write!(Path.join(shared, "media_cache/cached.webp"), "cache")

    # Like the Ansible deploy: the release's uploads is a symlink to shared/.
    link = Path.join(release_static, "uploads")
    File.ln_s!(shared, link)
    Application.put_env(:baudrate, :data_export_uploads_root, link)

    on_exit(fn ->
      Application.delete_env(:baudrate, :data_export_uploads_root)
      File.rm_rf(base)
    end)

    %{shared: shared, backups: backups}
  end

  defp archive_members(path) do
    {out, 0} = System.cmd("tar", ["-tzf", path])
    String.split(out, "\n", trim: true)
  end

  test "resolves the uploads symlink to the real directory", %{shared: shared} do
    {:ok, real_shared} = Baudrate.DataPortability.Files.realpath(shared)
    assert Backup.uploads_dir() == {:ok, real_shared}
  end

  test "archives the real uploads files, without the media cache", %{backups: backups} do
    assert {:ok, archive} = Backup.backup_files(backups)
    members = archive_members(archive)

    assert "uploads/avatars/abc/48.webp" in members
    refute Enum.any?(members, &String.contains?(&1, "media_cache"))
  end

  test "restores an archive back into the real uploads directory",
       %{shared: shared, backups: backups} do
    {:ok, archive} = Backup.backup_files(backups)
    File.rm_rf!(Path.join(shared, "avatars"))

    assert {:ok, _} = Backup.restore_files(archive)
    assert File.read!(Path.join(shared, "avatars/abc/48.webp")) == "avatar"
  end

  test "refuses unknown formats and missing files", %{backups: backups} do
    assert {:error, "Invalid format" <> _} = Backup.backup_db(backups, "zip")
    assert {:error, "Backup file not found" <> _} = Backup.restore_files("/nonexistent.tar.gz")
    assert {:error, "Backup file not found" <> _} = Backup.restore_db("/nonexistent.dump")
  end
end
