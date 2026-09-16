defmodule Baudrate.Backup.SnapshotsTest do
  # Not async: the restore test points the Repo configuration at a scratch
  # database for pg_restore, and async modules never run alongside this one.
  use ExUnit.Case, async: false

  alias Baudrate.Backup
  alias Baudrate.Backup.Snapshots

  @plenty %{free: 100 * 1024 * 1024 * 1024, total: 200 * 1024 * 1024 * 1024}

  setup do
    base =
      Path.join(System.tmp_dir!(), "baudrate-snapshots-#{System.unique_integer([:positive])}")

    uploads = Path.join(base, "shared/uploads")
    root = Path.join(base, "backups/daily")

    write_upload(uploads, "avatars/abc/48.webp", "avatar")
    write_upload(uploads, "article_images/one.webp", "image one")
    write_upload(uploads, "media_cache/cached.webp", "cache")

    on_exit(fn -> File.rm_rf(base) end)

    %{base: base, uploads: uploads, root: root}
  end

  defp write_upload(uploads, rel, content) do
    path = Path.join(uploads, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp opts(uploads, extra \\ []) do
    Keyword.merge([uploads_dir: uploads, free_space: fn _ -> {:ok, @plenty} end], extra)
  end

  defp at(minute), do: DateTime.new!(~D[2026-09-16], Time.new!(4, minute, 0), "Etc/UTC")

  defp inode(path), do: File.stat!(path).inode

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  test "creates a complete backup: a checked dump, uploads without the media cache, a manifest",
       %{uploads: uploads, root: root} do
    assert {:ok, result} = Snapshots.create(root, opts(uploads, now: at(30)))

    assert result.path == Path.join(realpath(root), "20260916T043000Z")
    assert {:ok, _} = Backup.verify_db_dump(Path.join(result.path, "db.dump"))
    assert File.read!(Path.join(result.path, "uploads/avatars/abc/48.webp")) == "avatar"
    refute File.exists?(Path.join(result.path, "uploads/media_cache"))
    assert %{files: 2, copied: 2, linked: 0} = result

    manifest = result.path |> Path.join("MANIFEST.json") |> File.read!() |> Jason.decode!()
    assert manifest["database"]["bytes"] == File.stat!(Path.join(result.path, "db.dump")).size
    assert manifest["database"]["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert manifest["uploads"]["files"] == 2
    assert Snapshots.list(root) == [result.path]
  end

  describe "CHECKSUMS.sha256" do
    test "covers the dump and every stored upload", %{uploads: uploads, root: root} do
      {:ok, backup} = Snapshots.create(root, opts(uploads))

      lines =
        backup.path
        |> Path.join("CHECKSUMS.sha256")
        |> File.read!()
        |> String.split("\n", trim: true)

      assert length(lines) == 3
      assert Enum.all?(lines, &(&1 =~ ~r/\A[0-9a-f]{64}  \S/))

      paths = Enum.map(lines, fn <<_::binary-size(64), "  ", path::binary>> -> path end)
      assert "db.dump" in paths
      assert "uploads/avatars/abc/48.webp" in paths
      assert "uploads/article_images/one.webp" in paths
      # The media cache is not part of a backup, so it is not in the list.
      refute Enum.any?(paths, &String.contains?(&1, "media_cache"))
    end

    test "records checksums that actually match the bytes", %{uploads: uploads, root: root} do
      {:ok, backup} = Snapshots.create(root, opts(uploads))

      for <<_::binary-size(64), "  ", _::binary>> = line <-
            backup.path
            |> Path.join("CHECKSUMS.sha256")
            |> File.read!()
            |> String.split("\n", trim: true) do
        <<recorded::binary-size(64), "  ", rel::binary>> = line
        assert recorded == sha256_of(Path.join(backup.path, rel)), "checksum wrong for #{rel}"
      end
    end

    test "the manifest carries the list's own checksum, so a truncated list is caught", %{
      uploads: uploads,
      root: root
    } do
      {:ok, backup} = Snapshots.create(root, opts(uploads))

      manifest = backup.path |> Path.join("MANIFEST.json") |> File.read!() |> Jason.decode!()

      assert manifest["checksums"]["file"] == "CHECKSUMS.sha256"
      assert manifest["checksums"]["entries"] == 3

      assert manifest["checksums"]["sha256"] ==
               sha256_of(Path.join(backup.path, "CHECKSUMS.sha256"))
    end

    test "is written with the same restricted mode as the rest", %{uploads: uploads, root: root} do
      {:ok, backup} = Snapshots.create(root, opts(uploads))

      assert mode(Path.join(backup.path, "CHECKSUMS.sha256")) == 0o640
    end

    test "carries a hard-linked file's checksum forward instead of re-reading it", %{
      uploads: uploads,
      root: root
    } do
      {:ok, first} = Snapshots.create(root, opts(uploads, now: at(10)))

      # Rot in the *stored* copy: the bytes decay on the backup disk, with size
      # and modification time unchanged, so the next backup still hard-links to
      # it rather than noticing anything. This is the case the carry-forward
      # exists for; corrupting the live source instead would prove nothing,
      # because a hard link keeps the previous backup's bytes either way.
      stored = Path.join(first.path, "uploads/avatars/abc/48.webp")
      stat = File.stat!(stored, time: :posix)
      File.write!(stored, "AVATAR")
      File.touch!(stored, stat.mtime)

      {:ok, second} = Snapshots.create(root, opts(uploads, now: at(20)))
      assert second.linked > 0

      # Re-hashing would have recorded the rotted bytes and certified them
      # intact for ever after. Carrying the first backup's value forward means
      # a verifier sees the mismatch.
      assert checksum_for(first.path, "uploads/avatars/abc/48.webp") ==
               checksum_for(second.path, "uploads/avatars/abc/48.webp")

      refute checksum_for(second.path, "uploads/avatars/abc/48.webp") ==
               sha256_of(Path.join(second.path, "uploads/avatars/abc/48.webp"))
    end

    test "hashes a file the previous backup had no checksum for", %{uploads: uploads, root: root} do
      # A backup taken before this file existed, then one after.
      {:ok, first} = Snapshots.create(root, opts(uploads, now: at(10)))
      File.rm!(Path.join(first.path, "CHECKSUMS.sha256"))

      {:ok, second} = Snapshots.create(root, opts(uploads, now: at(20)))

      assert second.linked > 0

      assert checksum_for(second.path, "uploads/avatars/abc/48.webp") ==
               sha256_of(Path.join(second.path, "uploads/avatars/abc/48.webp"))
    end
  end

  defp sha256_of(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end

  defp checksum_for(backup, rel) do
    backup
    |> Path.join("CHECKSUMS.sha256")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn <<hash::binary-size(64), "  ", path::binary>> ->
      path == rel && hash
    end)
  end

  # The pre-deploy dump runs from the deploy playbook, whose umask is not the
  # backup service's, and a dump holds every account's data.
  test "writes backups only the owner and the backup group can read", %{
    uploads: uploads,
    root: root,
    base: base
  } do
    {:ok, backup} = Snapshots.create(root, opts(uploads))

    {:ok, dump} =
      Snapshots.dump_database(Path.join(base, "predeploy"),
        free_space: fn _ -> {:ok, @plenty} end
      )

    assert mode(backup.path) == 0o750
    assert mode(Path.join(backup.path, "db.dump")) == 0o640
    assert mode(Path.join(backup.path, "MANIFEST.json")) == 0o640
    assert mode(dump.path) == 0o640
  end

  test "hard-links unchanged uploads to the previous backup and copies new or changed ones",
       %{uploads: uploads, root: root} do
    {:ok, first} = Snapshots.create(root, opts(uploads, now: at(0)))

    write_upload(uploads, "article_images/two.webp", "image two")
    changed = write_upload(uploads, "avatars/abc/48.webp", "new avatar")
    File.touch!(changed, System.os_time(:second) + 3600)

    {:ok, second} = Snapshots.create(root, opts(uploads, now: at(1)))

    assert %{files: 3, linked: 1, copied: 2} = second

    assert inode(Path.join(second.path, "uploads/article_images/one.webp")) ==
             inode(Path.join(first.path, "uploads/article_images/one.webp"))

    refute inode(Path.join(second.path, "uploads/avatars/abc/48.webp")) ==
             inode(Path.join(first.path, "uploads/avatars/abc/48.webp"))

    assert File.read!(Path.join(second.path, "uploads/avatars/abc/48.webp")) == "new avatar"
    assert File.read!(Path.join(first.path, "uploads/avatars/abc/48.webp")) == "avatar"
  end

  test "keeps the newest backups and removes older ones only after a new backup succeeded",
       %{uploads: uploads, root: root} do
    {:ok, oldest} = Snapshots.create(root, opts(uploads, now: at(0), keep: 2))
    {:ok, middle} = Snapshots.create(root, opts(uploads, now: at(1), keep: 2))
    assert Snapshots.list(root) == [middle.path, oldest.path]

    # A refused run removes nothing, however many backups there are.
    short = fn _ -> {:ok, %{free: 0, total: @plenty.total}} end

    assert {:error, _} =
             Snapshots.create(root, opts(uploads, now: at(2), keep: 1, free_space: short))

    assert Snapshots.list(root) == [middle.path, oldest.path]

    {:ok, newest} = Snapshots.create(root, opts(uploads, now: at(3), keep: 2))
    assert newest.removed == [oldest.path]
    assert Snapshots.list(root) == [newest.path, middle.path]
    # The removed backup's hard links do not affect the kept copies.
    assert File.read!(Path.join(newest.path, "uploads/article_images/one.webp")) == "image one"
  end

  test "refuses to start when the backup would leave too little free space",
       %{uploads: uploads, root: root} do
    two_gib = 2 * 1024 * 1024 * 1024
    tight = fn _ -> {:ok, %{free: two_gib, total: 100 * 1024 * 1024 * 1024}} end

    assert {:error, message} = Snapshots.create(root, opts(uploads, free_space: tight))
    assert message =~ "Not enough free space"
    assert message =~ "No backup was made and none was removed"
    assert Snapshots.list(root) == []
    refute Enum.any?(File.ls!(root), &String.starts_with?(&1, ".incomplete-"))
  end

  test "a failed dump leaves no backup folder behind and keeps the previous backups",
       %{uploads: uploads, root: root} do
    {:ok, good} = Snapshots.create(root, opts(uploads, now: at(0)))

    with_repo_config([database: "baudrate_no_such_database"], fn ->
      assert {:error, message} = Snapshots.create(root, opts(uploads, now: at(1)))
      assert message =~ "pg_dump failed"
    end)

    assert Snapshots.list(root) == [good.path]
    assert File.ls!(root) |> Enum.reject(&(&1 == Path.basename(good.path))) == []
  end

  test "removes a half-written backup left by an interrupted run", %{uploads: uploads, root: root} do
    leftover = Path.join(root, ".incomplete-20260101T000000Z/uploads")
    File.mkdir_p!(leftover)

    assert {:ok, _} = Snapshots.create(root, opts(uploads))
    refute File.exists?(Path.dirname(leftover))
  end

  test "refuses to run while another backup holds the lock, and clears a stale lock",
       %{uploads: uploads, root: root} do
    File.mkdir_p!(root)
    lock = Path.join(root, ".lock")

    File.write!(lock, System.pid())
    assert {:error, "Another backup is running" <> _} = Snapshots.create(root, opts(uploads))

    File.write!(lock, "2147483647")
    assert {:ok, _} = Snapshots.create(root, opts(uploads))
    refute File.exists?(lock)
  end

  test "does not follow symlinks in the uploads directory", %{
    base: base,
    uploads: uploads,
    root: root
  } do
    outside = Path.join(base, "secret.txt")
    File.write!(outside, "not an upload")
    File.ln_s!(outside, Path.join(uploads, "avatars/link.webp"))

    assert {:ok, result} = Snapshots.create(root, opts(uploads))
    refute File.exists?(Path.join(result.path, "uploads/avatars/link.webp"))
  end

  test "rejects a bad :keep", %{uploads: uploads, root: root} do
    assert {:error, ":keep must be a positive integer" <> _} =
             Snapshots.create(root, opts(uploads, keep: 0))
  end

  describe "dump_database/2" do
    test "writes checked, labelled dumps and keeps the newest ones", %{base: base} do
      root = Path.join(base, "backups/predeploy")
      free = fn _ -> {:ok, @plenty} end

      paths =
        for minute <- 0..3 do
          {:ok, %{path: path}} =
            Snapshots.dump_database(root,
              keep: 3,
              label: "v1.19.#{minute}",
              now: at(minute),
              free_space: free
            )

          path
        end

      assert Path.basename(List.last(paths)) == "20260916T040300Z-v1.19.3.dump"
      assert Snapshots.list_dumps(root) == paths |> Enum.drop(1) |> Enum.reverse()
      assert {:ok, _} = Backup.verify_db_dump(List.last(paths))
    end

    test "rejects labels that are not plain file name characters", %{base: base} do
      root = Path.join(base, "backups/predeploy")

      for label <- ["../escape", "v1 2", "", String.duplicate("a", 65)] do
        assert {:error, "Invalid label" <> _} = Snapshots.dump_database(root, label: label)
      end
    end
  end

  describe "restore/2" do
    test "restores the database and copies the uploads back", %{uploads: uploads, root: root} do
      {:ok, backup} = Snapshots.create(root, opts(uploads))

      File.rm_rf!(Path.join(uploads, "avatars"))
      write_upload(uploads, "article_images/after.webp", "added after the backup")

      scratch =
        Application.get_env(:baudrate, Baudrate.Repo)
        |> Keyword.put(:database, "baudrate_restore_test#{System.get_env("MIX_TEST_PARTITION")}")
        # template0 is never modified, so creating from it cannot inherit objects
        # (or a stale collation version) that another database added to template1.
        |> Keyword.put(:template, "template0")

      Ecto.Adapters.Postgres.storage_down(scratch)
      :ok = Ecto.Adapters.Postgres.storage_up(scratch)
      on_exit(fn -> Ecto.Adapters.Postgres.storage_down(scratch) end)

      with_repo_config([database: scratch[:database]], fn ->
        assert {:ok, %{files: 2}} = Snapshots.restore(backup.path, uploads_dir: uploads)
      end)

      assert File.read!(Path.join(uploads, "avatars/abc/48.webp")) == "avatar"

      assert File.read!(Path.join(uploads, "article_images/after.webp")) ==
               "added after the backup"

      {output, 0} =
        System.cmd(
          "psql",
          ["-At", "-c", "select count(*) from schema_migrations"] ++ psql_args(scratch),
          env: [{"PGPASSWORD", to_string(scratch[:password])}]
        )

      assert String.to_integer(String.trim(output)) > 0
    end

    test "refuses a folder that is not a complete backup", %{base: base} do
      assert {:error, "Not a complete backup" <> _} = Snapshots.restore(base)
    end
  end

  describe "release commands" do
    # The success paths are covered above; these wrappers must turn every
    # error into a raise, which makes `bin/baudrate eval` exit non-zero so
    # systemd and the deploy playbook see the failure.
    test "raise on failure instead of reporting success", %{base: base} do
      assert_raise RuntimeError, ~r/backup failed: :keep must be/, fn ->
        Baudrate.Release.snapshot_backup(Path.join(base, "daily"), keep: 0)
      end

      assert_raise RuntimeError, ~r/pre-deploy dump failed: Invalid label/, fn ->
        Baudrate.Release.predeploy_dump(Path.join(base, "predeploy"), label: "../x")
      end

      assert_raise RuntimeError, ~r/restore failed: Not a complete backup/, fn ->
        Baudrate.Release.restore_snapshot(base)
      end
    end
  end

  test "free_space/1 reads the filesystem of a path", %{base: base} do
    File.mkdir_p!(base)
    assert {:ok, %{free: free, total: total}} = Backup.free_space(base)
    assert total > 0 and free >= 0 and free <= total
  end

  defp with_repo_config(overrides, fun) do
    original = Application.get_env(:baudrate, Baudrate.Repo)
    Application.put_env(:baudrate, Baudrate.Repo, Keyword.merge(original, overrides))

    try do
      fun.()
    after
      Application.put_env(:baudrate, Baudrate.Repo, original)
    end
  end

  defp psql_args(config) do
    ["-U", config[:username], "-h", config[:hostname], "-d", config[:database]]
  end

  defp realpath(path) do
    {:ok, real} = Baudrate.DataPortability.Files.realpath(path)
    real
  end
end
