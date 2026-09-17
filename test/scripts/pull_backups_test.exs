defmodule Baudrate.Scripts.PullBackupsTest do
  @moduledoc """
  `scripts/pull-backups.sh` against backups written by the real
  `Baudrate.Backup.Snapshots.create/2`, so the contract between the server that
  records checksums and the machine that checks them is tested from both ends.

  A stand-in `ssh` on `PATH` runs rsync's remote side in a local directory, the
  way `rrsync -ro` does in production.
  """
  # Not async: every test runs pg_dump and rsync, and the snapshot tests next
  # door swap the Repo configuration.
  use ExUnit.Case, async: false

  alias Baudrate.Backup.Snapshots

  @script Path.expand("../../scripts/pull-backups.sh", __DIR__)
  @plenty %{free: 100 * 1024 * 1024 * 1024, total: 200 * 1024 * 1024 * 1024}

  setup do
    base = Path.join(System.tmp_dir!(), "baudrate-pull-#{System.unique_integer([:positive])}")
    server = Path.join(base, "server")
    uploads = Path.join(base, "uploads")
    dest = Path.join(base, "dest")
    bin = Path.join(base, "bin")

    File.mkdir_p!(Path.join(server, "predeploy"))
    write_file(Path.join(uploads, "avatars/abc/48.webp"), "avatar")
    write_file(Path.join(uploads, "article_images/one.webp"), "image one")

    # rsync runs `ssh [options] host rsync --server …`: skip to the host, then
    # run the command where the backups are.
    write_file(Path.join(bin, "ssh"), """
    #!/bin/sh
    while [ $# -gt 0 ]; do
      case "$1" in
        -i|-p|-o|-l) shift 2 ;;
        -*) shift ;;
        *) shift; break ;;
      esac
    done
    cd "$FAKE_SERVER" && exec "$@"
    """)

    File.chmod!(Path.join(bin, "ssh"), 0o755)
    on_exit(fn -> File.rm_rf(base) end)

    %{server: server, uploads: uploads, dest: dest, bin: bin}
  end

  test "pulls the newest backup and verifies every file in it", ctx do
    backup!(ctx, 10)

    assert {output, 0} = pull(ctx)
    assert output =~ "1 copies"
    assert output =~ "newest 20260916T041000Z"
    assert File.exists?(Path.join(ctx.dest, "daily/20260916T041000Z/CHECKSUMS.sha256"))
    assert File.exists?(Path.join(ctx.dest, ".verified/20260916T041000Z"))
  end

  test "a corrupted file fails the run", ctx do
    backup!(ctx, 10)
    File.write!(server_path(ctx, "041000", "uploads/article_images/one.webp"), "tampered")

    assert {output, 1} = pull(ctx)
    assert output =~ "do not match their recorded checksums"
  end

  # `sha256sum -c` checks only the lines it is given, and exits 0 on a
  # shortened list; the manifest's hash of the list is what catches it.
  test "a truncated checksum list fails the run", ctx do
    backup!(ctx, 10)
    list = server_path(ctx, "041000", "CHECKSUMS.sha256")
    lines = list |> File.read!() |> String.split("\n", trim: true)
    File.write!(list, Enum.join(Enum.drop(lines, -1), "\n") <> "\n")

    assert {output, 1} = pull(ctx)
    assert output =~ "CHECKSUMS.sha256 does not match the manifest"
  end

  describe "older copies" do
    test "each run verifies one, never-checked first, then the longest since checked", ctx do
      Enum.each([10, 20, 30], &backup!(ctx, &1))

      assert {output, 0} = pull(ctx)
      assert output =~ "newest 20260916T043000Z"
      assert output =~ "also verified 20260916T041000Z"

      assert {output, 0} = pull(ctx)
      assert output =~ "also verified 20260916T042000Z"

      stamps = Path.join(ctx.dest, ".verified")
      File.touch!(Path.join(stamps, "20260916T041000Z"), System.os_time(:second) - 3600)
      File.touch!(Path.join(stamps, "20260916T042000Z"), System.os_time(:second))

      assert {output, 0} = pull(ctx)
      assert output =~ "also verified 20260916T041000Z"
    end

    # Rot on this machine: same size and modification time, so rsync sees
    # nothing to repair and only the checksum can notice.
    test "rot in an older copy fails the run and names the copy", ctx do
      backup!(ctx, 10)
      backup!(ctx, 20)
      assert {_, 0} = pull(ctx)

      dump = Path.join(ctx.dest, "daily/20260916T041000Z/db.dump")
      %{mtime: mtime} = File.stat!(dump, time: :posix)
      bytes = File.read!(dump)
      last = :binary.last(bytes)

      File.write!(
        dump,
        binary_part(bytes, 0, byte_size(bytes) - 1) <> <<Bitwise.bxor(last, 1)>>
      )

      File.touch!(dump, mtime)

      assert {output, 1} = pull(ctx)
      assert output =~ "files in #{ctx.dest}/daily/20260916T041000Z do not match"
    end

    test "a copy from before checksum lists has its dump verified", ctx do
      backup!(ctx, 10)
      backup!(ctx, 20)
      File.rm!(server_path(ctx, "041000", "CHECKSUMS.sha256"))

      assert {output, 0} = pull(ctx)
      assert output =~ "20260916T041000Z predates CHECKSUMS.sha256; only the dump was verified"
      assert output =~ "also verified 20260916T041000Z"
    end

    test "stamps of copies removed by retention are removed too", ctx do
      Enum.each([10, 20, 30], &backup!(ctx, &1))
      assert {_, 0} = pull(ctx)
      assert File.exists?(Path.join(ctx.dest, ".verified/20260916T041000Z"))

      assert {_, 0} = pull(ctx, [{"BAUDRATE_BACKUP_KEEP", "2"}])
      refute File.exists?(Path.join(ctx.dest, "daily/20260916T041000Z"))
      refute File.exists?(Path.join(ctx.dest, ".verified/20260916T041000Z"))
    end
  end

  test "a backup still being built is neither pulled nor counted", ctx do
    backup!(ctx, 10)
    write_file(Path.join(ctx.server, "daily/.incomplete-20260916T043000Z/db.dump"), "partial")
    leftover = Path.join(ctx.dest, "daily/.incomplete-20260915T043000Z")
    write_file(Path.join(leftover, "db.dump"), "left by an older pull")

    assert {output, 0} = pull(ctx)
    assert output =~ "1 copies"
    refute output =~ "also verified"
    refute File.exists?(Path.join(ctx.dest, "daily/.incomplete-20260916T043000Z"))
    refute File.exists?(leftover)
  end

  test "a stale newest backup exits 2", ctx do
    backup!(ctx, 10)
    File.touch!(server_path(ctx, "041000", "MANIFEST.json"), System.os_time(:second) - 3 * 86_400)

    assert {output, 2} = pull(ctx)
    assert output =~ "backups on the server may have stopped running"
  end

  defp backup!(ctx, minute) do
    now = DateTime.new!(~D[2026-09-16], Time.new!(4, minute, 0), "Etc/UTC")

    {:ok, _} =
      Snapshots.create(Path.join(ctx.server, "daily"),
        uploads_dir: ctx.uploads,
        free_space: fn _ -> {:ok, @plenty} end,
        now: now
      )
  end

  defp server_path(ctx, hhmmss, rel),
    do: Path.join([ctx.server, "daily", "20260916T#{hhmmss}Z", rel])

  defp pull(ctx, env \\ []) do
    System.cmd("sh", [@script],
      env:
        [
          {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
          {"FAKE_SERVER", ctx.server},
          {"BAUDRATE_BACKUP_HOST", "pull@backup-host"},
          {"BAUDRATE_BACKUP_KEY", "/nonexistent"},
          {"BAUDRATE_BACKUP_DEST", ctx.dest}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  defp write_file(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
