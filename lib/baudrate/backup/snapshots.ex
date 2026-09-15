defmodule Baudrate.Backup.Snapshots do
  @moduledoc """
  Scheduled backups kept as complete folders with count-based retention
  (ADR 0028). `Baudrate.Release.snapshot_backup/2` and `predeploy_dump/2`
  call this from the systemd timer and the deploy playbook.

  ## A backup

  `create/2` writes `<root>/<YYYYMMDDTHHMMSSZ>/` (UTC) holding:

    * `db.dump` — `pg_dump -Fc`, checked with `pg_restore --list`.
    * `uploads/` — the uploads directory without `media_cache/`. A file whose
      size and modification time match its copy in the previous backup is
      hard-linked to that copy instead of copied. Uploads get fresh random
      names and are never rewritten in place, so a week of backups costs
      about one copy of the uploads plus the files added since.
    * `MANIFEST.json` — application version, time, dump size and SHA-256,
      and file counts.

  `dump_database/2` writes single `<timestamp>-<label>.dump` files, used
  before migrations.

  ## Rules that keep a small server safe

    * **Complete or absent.** A backup is built under `.incomplete-…` and
      renamed only after every step and check succeeded. A failed run removes
      what it wrote and deletes nothing else.
    * **Never fill the disk.** A run refuses to start when the free space left
      after it (estimated from the last dump and the files to copy) would drop
      below 1 GiB or 10% of the filesystem, whichever is larger. A full disk
      stops PostgreSQL and the site, which is worse than a missed backup.
    * **Retention counts backups, not days.** `:keep` removes the oldest
      complete backups beyond that number, and only after a new backup
      succeeded, so a run of failures can never delete the last good copies.
    * **One run at a time.** A lock file (holding the OS process id) keeps a
      manual run and the timer from removing each other's work.

  Every function returns `{:ok, result}` or `{:error, message}`.
  """

  alias Baudrate.Backup

  @backup_name ~r/\A\d{8}T\d{6}Z\z/
  @dump_name ~r/\A\d{8}T\d{6}Z(-[A-Za-z0-9._-]+)?\.dump\z/
  @label ~r/\A[A-Za-z0-9._-]{1,64}\z/
  @gib 1024 * 1024 * 1024
  # Assumed size of a first dump, before there is a previous one to measure.
  @first_dump_estimate 512 * 1024 * 1024

  @doc """
  Creates a backup folder in `root` and keeps the newest `:keep` (default 7).

  Options, mainly for tests: `:uploads_dir` (default
  `Baudrate.Backup.uploads_dir/0`), `:now` (a `DateTime`), `:free_space`
  (a function like `Baudrate.Backup.free_space/1`).
  """
  @spec create(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def create(root, opts \\ []) do
    keep = Keyword.get(opts, :keep, 7)

    with :ok <- validate_keep(keep),
         {:ok, uploads} <- uploads_dir(opts),
         :ok <- File.mkdir_p(root),
         {:ok, root} <- realpath(root) do
      with_lock(root, fn ->
        remove_incomplete(root)
        previous = List.first(list(root))
        name = timestamp(opts)
        target = Path.join(root, name)
        building = Path.join(root, ".incomplete-" <> name)
        plan = plan_uploads(uploads, previous && Path.join(previous, "uploads"))

        with :ok <- ensure_absent(target),
             :ok <- check_space(root, dump_estimate(previous) + plan.copy_bytes, opts),
             {:ok, result} <- build(building, plan) do
          File.rename!(building, target)
          removed = prune(list(root), keep)
          {:ok, Map.merge(result, %{path: target, removed: removed})}
        else
          error ->
            File.rm_rf(building)
            error
        end
      end)
    end
  end

  @doc """
  Writes a checked database dump `<timestamp>-<label>.dump` into `root` and
  keeps the newest `:keep` dumps (default 3). `:label` (default none) may use
  letters, digits, `.`, `_` and `-`, e.g. the release tag.
  """
  @spec dump_database(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def dump_database(root, opts \\ []) do
    keep = Keyword.get(opts, :keep, 3)
    label = Keyword.get(opts, :label)

    with :ok <- validate_keep(keep),
         :ok <- validate_label(label),
         :ok <- File.mkdir_p(root),
         {:ok, root} <- realpath(root) do
      with_lock(root, fn ->
        remove_incomplete(root)
        name = timestamp(opts) <> if(label, do: "-" <> label, else: "") <> ".dump"
        target = Path.join(root, name)
        building = Path.join(root, ".incomplete-" <> name)

        with :ok <- ensure_absent(target),
             :ok <- check_space(root, dump_estimate(List.first(list_dumps(root))), opts),
             {:ok, _} <- Backup.dump_db_to(building),
             {:ok, _} <- Backup.verify_db_dump(building) do
          File.rename!(building, target)
          removed = prune(list_dumps(root), keep)
          {:ok, %{path: target, bytes: File.stat!(target).size, removed: removed}}
        else
          error ->
            File.rm(building)
            error
        end
      end)
    end
  end

  @doc """
  Restores a backup folder made by `create/2`: the database (overwriting it)
  and the uploaded files, copied back over the uploads directory. Files added
  after the backup are left in place. **Stop the service first.**
  """
  @spec restore(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def restore(backup, opts \\ []) do
    dump = Path.join(backup, "db.dump")
    saved_uploads = Path.join(backup, "uploads")

    cond do
      not File.regular?(Path.join(backup, "MANIFEST.json")) ->
        {:error, "Not a complete backup (no MANIFEST.json): #{backup}"}

      not File.regular?(dump) ->
        {:error, "Backup has no db.dump: #{backup}"}

      true ->
        with {:ok, uploads} <- uploads_dir(opts),
             {:ok, _} <- Backup.verify_db_dump(dump),
             {:ok, _} <- Backup.restore_db(dump) do
          files = copy_tree(saved_uploads, uploads)
          {:ok, %{database: dump, uploads: uploads, files: files}}
        end
    end
  end

  @doc "Complete backup folders in `root`, newest first."
  @spec list(String.t()) :: [String.t()]
  def list(root), do: entries(root, @backup_name, &File.dir?/1)

  @doc "Complete database dumps in `root`, newest first."
  @spec list_dumps(String.t()) :: [String.t()]
  def list_dumps(root), do: entries(root, @dump_name, &File.regular?/1)

  # -- building -------------------------------------------------------------

  defp build(dir, plan) do
    dump = Path.join(dir, "db.dump")
    File.mkdir_p!(dir)

    with {:ok, _} <- Backup.dump_db_to(dump),
         {:ok, _} <- Backup.verify_db_dump(dump),
         {:ok, counts} <- snapshot(plan, Path.join(dir, "uploads")) do
      manifest = %{
        version: to_string(Application.spec(:baudrate, :vsn) || "unknown"),
        created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        database: %{file: "db.dump", bytes: File.stat!(dump).size, sha256: sha256(dump)},
        uploads: counts
      }

      File.write!(
        Path.join(dir, "MANIFEST.json"),
        Jason.encode_to_iodata!(manifest, pretty: true)
      )

      {:ok, Map.merge(counts, %{db_bytes: manifest.database.bytes})}
    end
  end

  # Walks the uploads once to decide, per file, between a hard link to the
  # previous backup and a copy, so the free-space check knows how much will be
  # written. Only regular files and directories are followed; symlinks and
  # special files are skipped. `media_cache/` (top level) is left out.
  defp plan_uploads(uploads, previous) do
    uploads
    |> walk("")
    |> Enum.reduce(%{source: uploads, dirs: [], files: [], copy_bytes: 0}, fn
      {:dir, rel}, plan ->
        %{plan | dirs: [rel | plan.dirs]}

      {:file, rel, stat}, plan ->
        action = if linkable?(previous, rel, stat), do: :link, else: :copy
        bytes = if action == :copy, do: stat.size, else: 0
        %{plan | files: [{rel, action, stat} | plan.files], copy_bytes: plan.copy_bytes + bytes}
    end)
    |> Map.put(:previous, previous)
  end

  defp walk(dir, rel) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reject(&(rel == "" and &1 == "media_cache"))
        |> Enum.flat_map(fn name ->
          path = Path.join(dir, name)
          child = if rel == "", do: name, else: Path.join(rel, name)

          case File.lstat(path, time: :posix) do
            {:ok, %File.Stat{type: :directory}} -> [{:dir, child} | walk(path, child)]
            {:ok, %File.Stat{type: :regular} = stat} -> [{:file, child, stat}]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp linkable?(nil, _rel, _stat), do: false

  defp linkable?(previous, rel, stat) do
    case File.lstat(Path.join(previous, rel), time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        size == stat.size and mtime == stat.mtime

      _ ->
        false
    end
  end

  defp snapshot(plan, dest) do
    File.mkdir_p!(dest)
    plan.dirs |> Enum.reverse() |> Enum.each(&File.mkdir_p!(Path.join(dest, &1)))

    counts =
      plan.files
      |> Enum.reverse()
      |> Enum.reduce(%{files: 0, linked: 0, copied: 0, bytes: 0}, fn {rel, action, stat}, acc ->
        target = Path.join(dest, rel)

        case store(action, Path.join(plan.source, rel), plan.previous, rel, target, stat) do
          :linked ->
            %{acc | files: acc.files + 1, linked: acc.linked + 1, bytes: acc.bytes + stat.size}

          :copied ->
            %{acc | files: acc.files + 1, copied: acc.copied + 1, bytes: acc.bytes + stat.size}

          # Deleted between planning and copying: it is no longer an upload.
          :gone ->
            acc
        end
      end)

    {:ok, counts}
  rescue
    e in File.Error -> {:error, "Copying uploads failed: #{Exception.message(e)}"}
  end

  defp store(:link, source, previous, rel, target, stat) do
    case File.ln(Path.join(previous, rel), target) do
      :ok -> :linked
      {:error, _} -> store(:copy, source, previous, rel, target, stat)
    end
  end

  defp store(:copy, source, _previous, _rel, target, stat) do
    case File.cp(source, target) do
      :ok ->
        # Keep the modification time, so the next backup can link to this copy.
        File.touch!(target, stat.mtime)
        :copied

      {:error, :enoent} ->
        :gone

      {:error, reason} ->
        raise File.Error, reason: reason, action: "copy", path: source
    end
  end

  defp copy_tree(from, to) do
    from
    |> walk("")
    |> Enum.reduce(0, fn
      {:dir, rel}, count ->
        File.mkdir_p!(Path.join(to, rel))
        count

      {:file, rel, stat}, count ->
        target = Path.join(to, rel)
        File.cp!(Path.join(from, rel), target)
        File.touch!(target, stat.mtime)
        count + 1
    end)
  end

  # -- safety ---------------------------------------------------------------

  defp check_space(root, estimate, opts) do
    free_space = Keyword.get(opts, :free_space, &Backup.free_space/1)

    with {:ok, %{free: free, total: total}} <- free_space.(root) do
      margin = max(@gib, div(total, 10))

      if free - estimate >= margin do
        :ok
      else
        {:error,
         "Not enough free space in #{root}: #{Backup.format_size(free)} free, " <>
           "this backup needs about #{Backup.format_size(estimate)} and must leave " <>
           "#{Backup.format_size(margin)}. No backup was made and none was removed."}
      end
    end
  end

  defp dump_estimate(nil), do: @first_dump_estimate

  defp dump_estimate(previous) do
    path = if File.dir?(previous), do: Path.join(previous, "db.dump"), else: previous

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> 2 * size
      _ -> @first_dump_estimate
    end
  end

  defp with_lock(root, fun) do
    lock = Path.join(root, ".lock")

    case take_lock(lock) do
      :ok ->
        try do
          fun.()
        after
          File.rm(lock)
        end

      error ->
        error
    end
  end

  defp take_lock(lock) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, System.pid())
        File.close(io)
        :ok

      {:error, :eexist} ->
        if lock_holder_alive?(lock) do
          {:error, "Another backup is running (#{lock})"}
        else
          File.rm(lock)
          take_lock_once(lock)
        end

      {:error, reason} ->
        {:error, "Cannot create #{lock}: #{:file.format_error(reason)}"}
    end
  end

  defp take_lock_once(lock) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, System.pid())
        File.close(io)
        :ok

      {:error, _} ->
        {:error, "Another backup is running (#{lock})"}
    end
  end

  defp lock_holder_alive?(lock) do
    case File.read(lock) do
      {:ok, pid} ->
        case Integer.parse(String.trim(pid)) do
          {pid, ""} -> File.exists?("/proc/#{pid}")
          _ -> false
        end

      _ ->
        false
    end
  end

  # A crash or power loss can leave a half-written backup; it is never counted
  # and only takes space.
  defp remove_incomplete(root) do
    root
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".incomplete-"))
    |> Enum.each(&File.rm_rf!(Path.join(root, &1)))
  end

  defp prune(complete, keep) do
    complete
    |> Enum.drop(keep)
    |> Enum.map(fn path ->
      File.rm_rf!(path)
      path
    end)
  end

  defp entries(root, pattern, type?) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(pattern, &1))
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(type?)
        |> Enum.sort(:desc)

      {:error, _} ->
        []
    end
  end

  defp ensure_absent(target) do
    if File.exists?(target), do: {:error, "#{target} already exists"}, else: :ok
  end

  defp validate_keep(keep) when is_integer(keep) and keep >= 1, do: :ok
  defp validate_keep(keep), do: {:error, ":keep must be a positive integer, got #{inspect(keep)}"}

  defp validate_label(nil), do: :ok

  defp validate_label(label) when is_binary(label) do
    if Regex.match?(@label, label), do: :ok, else: {:error, "Invalid label: #{inspect(label)}"}
  end

  defp validate_label(label), do: {:error, "Invalid label: #{inspect(label)}"}

  defp uploads_dir(opts) do
    case Keyword.fetch(opts, :uploads_dir) do
      {:ok, dir} -> realpath(dir)
      :error -> Backup.uploads_dir()
    end
  end

  defp realpath(path) do
    case Baudrate.DataPortability.Files.realpath(path) do
      {:ok, real} -> {:ok, real}
      :error -> {:error, "Directory not found: #{path}"}
    end
  end

  defp timestamp(opts) do
    opts
    |> Keyword.get_lazy(:now, &DateTime.utc_now/0)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
