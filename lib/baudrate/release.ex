defmodule Baudrate.Release do
  @moduledoc """
  Release tasks for running migrations, rollbacks, and one-shot data
  maintenance in production.

  Mix tasks aren't available inside an OTP release; invoke these via
  `bin/baudrate eval` (boots only the bits each task needs — repo for
  data tasks, migrator for schema tasks — so it never collides with the
  running production node) or `bin/baudrate rpc` (executes inside the
  already-running production node, useful when you'd prefer to reuse
  the live application's state):

      bin/baudrate eval "Baudrate.Release.migrate"
      bin/baudrate eval "Baudrate.Release.rollback(Baudrate.Repo, 20240101000000)"
      bin/baudrate eval "Baudrate.Release.backfill_ap_ids()"
      bin/baudrate eval "Baudrate.Release.backfill_ap_ids(dry_run: true)"

      # Or against the already-running node — same function, no port collision
      # because no second VM boots:
      bin/baudrate rpc "Baudrate.Release.backfill_ap_ids(dry_run: true)"

      # Backup and restore (Mix tasks are not in a release):
      bin/baudrate eval 'Baudrate.Release.backup("/var/backups/baudrate")'

      # Audited SysOp data export (ADR 0023), after verifying identity out of band:
      bin/baudrate eval 'Baudrate.Release.export_user_data("alice", "/root/exports", reason: "ticket 42")'
  """

  import Ecto.Query

  require Logger

  alias Baudrate.Content.{Article, Comment, Poll}
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @app :baudrate

  @doc """
  Runs all pending Ecto migrations.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Rolls back the given repo to the specified migration version.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Brings local articles', polls' and comments' `ap_id` fields up to the
  canonical scheme.

  Two passes, both idempotent and resumable:

    * **Missing ids.** ap_id stamping is part of the same transaction as the
      insert (since v1.8.2), but rows from earlier code paths may carry
      `ap_id = nil` if a process crashed between the commit and the separate
      post-commit `Repo.update!/1` that stamped them.
    * **Fragment ids (Phase 3B, ADR 0050).** Comments were stamped
      `<actor>#note-N` and polls `<article-uri>#poll`. A fragment never reaches
      the server, so dereferencing either returned the actor or the article and
      no remote instance could resolve the object. Both are rewritten to
      `/ap/comments/:id` and `/ap/polls/:id`, and the **previous id is kept in
      `legacy_ap_id`** — it is the identity peers already hold, so inbound
      lookups match either and a withdrawal names both. A row whose
      `legacy_ap_id` is already set is left alone, which is what makes a
      re-run after an interruption safe.

  Skipped:
    * Remote rows (`remote_actor_id` non-nil) — those carry the
      originating server's `ap_id` and must not be rewritten.
    * Local rows for which the canonical URI cannot be derived (e.g. a
      local comment whose author was hard-deleted before stamping).

  ## Options

    * `:dry_run` — when true, log what would be stamped without writing.

  Returns a map with `:articles`, `:polls`, and `:comments` keys, each a
  `{found, written}` tuple, where `found` counts both passes.

  ## Implementation note

  When invoked through `bin/baudrate eval`, this function uses
  `Ecto.Migrator.with_repo/2` to start *only* the repo for the duration
  of the task. It does NOT call `Application.ensure_all_started/1`,
  which would boot the full supervision tree (including
  `BaudrateWeb.Endpoint`) and collide with the running production node.
  Through `bin/baudrate rpc` the repo is already running, so
  `with_repo` short-circuits gracefully.
  """
  @spec backfill_ap_ids(keyword()) :: %{
          articles: {non_neg_integer(), non_neg_integer()},
          polls: {non_neg_integer(), non_neg_integer()},
          comments: {non_neg_integer(), non_neg_integer()}
        }
  def backfill_ap_ids(opts \\ []) do
    load_app()
    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      Logger.info("backfill_ap_ids: dry run — no changes will be written")
    end

    [repo] = repos()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(repo, fn _repo ->
        run_backfill(dry_run)
      end)

    {a_total, a_stamped} = result.articles
    {p_total, p_stamped} = result.polls
    {c_total, c_stamped} = result.comments

    Logger.info(
      "backfill_ap_ids: complete — articles=#{a_stamped}/#{a_total} polls=#{p_stamped}/#{p_total} comments=#{c_stamped}/#{c_total}"
    )

    result
  end

  # --- Implementation ---

  defp run_backfill(dry_run) do
    base = base_url_from_config()

    %{
      articles: backfill_articles(dry_run, base),
      polls: backfill_polls(dry_run, base),
      comments: backfill_comments(dry_run, base)
    }
  end

  defp backfill_articles(dry_run, base) do
    rows =
      from(a in Article,
        where: is_nil(a.ap_id) and is_nil(a.remote_actor_id) and not is_nil(a.slug),
        select: %{id: a.id, slug: a.slug}
      )
      |> Repo.all()

    Logger.info("backfill_ap_ids: found #{length(rows)} local article(s) with nil ap_id")

    stamped =
      Enum.reduce(rows, 0, fn %{id: id, slug: slug}, acc ->
        ap_id = "#{base}/ap/articles/#{slug}"
        stamp_row(Article, id, [ap_id: ap_id], "article", dry_run, acc)
      end)

    {length(rows), stamped}
  end

  defp backfill_polls(dry_run, base) do
    unstamped =
      from(p in Poll,
        join: a in Article,
        on: a.id == p.article_id,
        where: is_nil(p.ap_id) and is_nil(a.remote_actor_id) and not is_nil(a.slug),
        select: %{id: p.id}
      )
      |> Repo.all()

    # `<article-uri>#poll`, the pre-ADR-0050 form. Only rows that have not been
    # rewritten yet, so a re-run after an interruption resumes rather than
    # overwriting a legacy id that is already recorded.
    fragmented =
      from(p in Poll,
        join: a in Article,
        on: a.id == p.article_id,
        where:
          is_nil(a.remote_actor_id) and is_nil(p.legacy_ap_id) and
            like(p.ap_id, "%#poll"),
        select: %{id: p.id, ap_id: p.ap_id}
      )
      |> Repo.all()

    Logger.info(
      "backfill_ap_ids: found #{length(unstamped)} local poll(s) with nil ap_id, " <>
        "#{length(fragmented)} with a fragment ap_id"
    )

    stamped =
      Enum.reduce(unstamped, 0, fn %{id: id}, acc ->
        stamp_row(Poll, id, [ap_id: poll_uri(base, id)], "poll", dry_run, acc)
      end)

    stamped =
      Enum.reduce(fragmented, stamped, fn %{id: id, ap_id: old}, acc ->
        stamp_row(
          Poll,
          id,
          [ap_id: poll_uri(base, id), legacy_ap_id: old],
          "poll (rewrite)",
          dry_run,
          acc
        )
      end)

    {length(unstamped) + length(fragmented), stamped}
  end

  defp backfill_comments(dry_run, base) do
    unstamped =
      from(c in Comment,
        join: a in Article,
        on: a.id == c.article_id,
        join: u in User,
        on: u.id == c.user_id,
        where: is_nil(c.ap_id) and is_nil(c.remote_actor_id),
        select: %{id: c.id, slug: a.slug}
      )
      |> Repo.all()

    # `<actor>#note-N`, the pre-ADR-0050 form. Matched on the fragment rather
    # than on a prefix: the base URL may have changed since the row was
    # written, and the fragment is what made the id undereferenceable.
    fragmented =
      from(c in Comment,
        where:
          is_nil(c.remote_actor_id) and is_nil(c.legacy_ap_id) and
            like(c.ap_id, "%#note-%"),
        select: %{id: c.id, ap_id: c.ap_id}
      )
      |> Repo.all()

    Logger.info(
      "backfill_ap_ids: found #{length(unstamped)} local comment(s) with nil ap_id, " <>
        "#{length(fragmented)} with a fragment ap_id"
    )

    stamped =
      Enum.reduce(unstamped, 0, fn %{id: id, slug: slug}, acc ->
        changes = [ap_id: comment_uri(base, id), url: "#{base}/articles/#{slug}#comment-#{id}"]
        stamp_row(Comment, id, changes, "comment", dry_run, acc)
      end)

    stamped =
      Enum.reduce(fragmented, stamped, fn %{id: id, ap_id: old}, acc ->
        stamp_row(
          Comment,
          id,
          [ap_id: comment_uri(base, id), legacy_ap_id: old],
          "comment (rewrite)",
          dry_run,
          acc
        )
      end)

    {length(unstamped) + length(fragmented), stamped}
  end

  defp comment_uri(base, id), do: "#{base}/ap/comments/#{id}"
  defp poll_uri(base, id), do: "#{base}/ap/polls/#{id}"

  defp stamp_row(_schema, id, changes, label, true = _dry_run, acc) do
    Logger.info("backfill_ap_ids: [dry] #{label} ##{id} would set #{inspect(changes)}")
    acc + 1
  end

  defp stamp_row(schema, id, changes, label, false, acc) do
    case Repo.get(schema, id) do
      nil ->
        acc

      row ->
        row
        |> Ecto.Changeset.change(changes)
        # Stamping an id is housekeeping, not an edit, so it must not move
        # `updated_at`. It did, and months later the rows it touched began
        # federating as edited on the day of the backfill — `updated_at` is
        # read by anything asking "when did this last change", and a repair
        # pass is the one write that most wants to be invisible to that.
        |> Ecto.Changeset.force_change(:updated_at, row.updated_at)
        |> Repo.update()
        |> case do
          {:ok, _} ->
            Logger.info("backfill_ap_ids: stamped #{label} ##{id}")
            acc + 1

          {:error, changeset} ->
            Logger.warning(
              "backfill_ap_ids: #{label} ##{id} skipped — #{inspect(changeset.errors)}"
            )

            acc
        end
    end
  end

  @doc """
  Re-encrypts stored secrets under the current encryption key (ADR 0038).

  Run it after configuring `BAUDRATE_AUTH_KEYS` / `BAUDRATE_SIGNING_KEYS`, and
  again after putting a new key in front of them. It is safe to run against
  the live node, safe to interrupt and safe to repeat: each row is rewritten
  on its own, only when it is not already on the current key, and only while
  it still holds what was read.

      bin/baudrate rpc "Baudrate.Release.rotate_keys(dry_run: true)"
      bin/baudrate rpc "Baudrate.Release.rotate_keys()"
      bin/baudrate rpc "Baudrate.Release.rotate_keys(only: [:signing], batch: 50)"

  It ends with a census of how many stored values sit under each key. A
  retired key may be removed from the configuration only once nothing is
  listed under it — including `recovery_codes.code_hash`, which cannot be
  re-encrypted at all: those rows move to the current key only when a member
  generates new codes, and dropping their key takes away that member's way
  back into their account.

  ## Options

    * `:dry_run` — report what would change and write nothing
    * `:only` — `[:auth]` or `[:signing]`; both by default
    * `:batch` — rows read at a time (200 by default)
  """
  @spec rotate_keys(keyword()) :: Baudrate.Crypto.Rekey.result()
  def rotate_keys(opts \\ []) do
    load_app()
    [repo] = repos()

    separated =
      Enum.filter(Baudrate.Crypto.Keyring.classes(), &Baudrate.Crypto.Keyring.separated?(&1))

    if separated == [] do
      IO.puts("""
      No encryption keys are configured, so there is nothing to rotate: every
      secret is protected by the key derived from SECRET_KEY_BASE, which is
      what this task moves away from.

      Generate a key per class:

          openssl rand -base64 32

      set BAUDRATE_AUTH_KEYS="k1:<key>" and BAUDRATE_SIGNING_KEYS="k1:<key>",
      restart, then run this again. See doc/sysop.md, "Rotating an encryption
      key".
      """)
    end

    {:ok, result, _} =
      Ecto.Migrator.with_repo(repo, fn _repo ->
        Baudrate.Crypto.Rekey.run(opts)
      end)

    result
  end

  @doc """
  Prints how many stored secrets sit under each encryption key (ADR 0038).

  The same census `rotate_keys/1` ends with, and what the detailed health
  report's `encryption_keys` check reads.

      bin/baudrate rpc "Baudrate.Release.key_census()"
  """
  @spec key_census() :: Baudrate.Crypto.Rekey.usage()
  def key_census do
    load_app()
    [repo] = repos()

    {:ok, usage, _} =
      Ecto.Migrator.with_repo(repo, fn _repo -> Baudrate.Crypto.Rekey.usage() end)

    for {target, counts} <- Enum.sort(usage), counts != %{} do
      inner = Enum.map_join(counts, " ", fn {id, count} -> "#{id}=#{count}" end)
      IO.puts("#{target}: #{inner}")
    end

    usage
  end

  @doc """
  Backs up the database and the uploads directory into `output_dir`
  (`Baudrate.Backup.backup/2`). Mix is not available in a release, so this is
  how an Ansible install takes a backup:

      bin/baudrate eval 'Baudrate.Release.backup("/var/backups/baudrate")'

  Options: `:format` — `"custom"` (default) or `"sql"`. Prints the two file
  paths; raises (a non-zero exit from `eval`) on failure, so cron notices.
  `output_dir` should be owner-only and outside every web root: the dump holds
  every account's data.
  """
  def backup(output_dir, opts \\ []) do
    load_app()

    case Baudrate.Backup.backup(output_dir, opts) do
      {:ok, %{db: db, files: files}} ->
        IO.puts("database: #{db}")
        IO.puts("files: #{files}")
        :ok

      {:error, message} ->
        raise "backup failed: #{message}"
    end
  end

  @doc """
  Restores a database dump and an uploads archive made by `backup/2`.
  **Stop the service first**; this overwrites the database and uploaded files.

      systemctl stop baudrate
      bin/baudrate eval 'Baudrate.Release.restore("/var/backups/baudrate/baudrate_db_….dump", "/var/backups/baudrate/baudrate_files_….tar.gz")'
  """
  def restore(db_backup, files_backup) do
    load_app()

    with {:ok, _} <- Baudrate.Backup.restore_db(db_backup),
         {:ok, uploads} <- Baudrate.Backup.restore_files(files_backup) do
      IO.puts("restored database from #{db_backup} and files into #{uploads}")
      :ok
    else
      {:error, message} -> raise "restore failed: #{message}"
    end
  end

  @doc """
  Makes a scheduled backup in `root` and keeps the newest `:keep` (default 7)
  (`Baudrate.Backup.Snapshots.create/2`, ADR 0028): a folder with a checked
  database dump, a hard-link snapshot of the uploads and a manifest. The
  systemd timer from the Ansible `backup` role runs:

      bin/baudrate eval 'Baudrate.Release.snapshot_backup("/var/backups/baudrate/daily", keep: 7)'

  Prints what was written and removed. Raises on failure, so `eval` exits
  non-zero and systemd records the run as failed; nothing else is removed then.
  """
  def snapshot_backup(root, opts \\ []) do
    load_app()

    case Baudrate.Backup.Snapshots.create(root, Keyword.take(opts, [:keep])) do
      {:ok, result} ->
        IO.puts("backup: #{result.path}")

        IO.puts(
          "database dump: #{Baudrate.Backup.format_size(result.db_bytes)}; uploads: " <>
            "#{result.files} files (#{result.copied} copied, #{result.linked} hard-linked)"
        )

        Enum.each(result.removed, &IO.puts("removed: #{&1}"))
        :ok

      {:error, message} ->
        raise "backup failed: #{message}"
    end
  end

  @doc """
  Dumps the database into `root` before a deploy runs migrations, keeping the
  newest `:keep` dumps (default 3). `:label` names the dump, e.g. the release
  tag (`Baudrate.Backup.Snapshots.dump_database/2`).

      bin/baudrate eval 'Baudrate.Release.predeploy_dump("/var/backups/baudrate/predeploy", label: "v1.19.5")'
  """
  def predeploy_dump(root, opts \\ []) do
    load_app()

    case Baudrate.Backup.Snapshots.dump_database(root, Keyword.take(opts, [:keep, :label])) do
      {:ok, result} ->
        IO.puts("database dump: #{result.path} (#{Baudrate.Backup.format_size(result.bytes)})")
        Enum.each(result.removed, &IO.puts("removed: #{&1}"))
        :ok

      {:error, message} ->
        raise "pre-deploy dump failed: #{message}"
    end
  end

  @doc """
  Restores a backup folder made by `snapshot_backup/2`: the database
  (overwritten) and the uploads (copied back; files added since are kept).
  **Stop the service first.**

      systemctl stop baudrate
      bin/baudrate eval 'Baudrate.Release.restore_snapshot("/var/backups/baudrate/daily/20260916T203000Z")'

  A pre-deploy dump is a plain `.dump` file; restore it with `restore_db/1`.
  """
  def restore_snapshot(path) do
    load_app()

    case Baudrate.Backup.Snapshots.restore(path) do
      {:ok, result} ->
        IO.puts("restored database from #{result.database}")
        IO.puts("restored #{result.files} files into #{result.uploads}")
        :ok

      {:error, message} ->
        raise "restore failed: #{message}"
    end
  end

  @doc """
  Restores only the database from a `.dump` or `.sql` file, such as a
  pre-deploy dump. **Stop the service first.**

      bin/baudrate eval 'Baudrate.Release.restore_db("/var/backups/baudrate/predeploy/20260916T101500Z-v1.19.5.dump")'
  """
  def restore_db(path) do
    load_app()

    case Baudrate.Backup.restore_db(path) do
      {:ok, _} ->
        IO.puts("restored database from #{path}")
        :ok

      {:error, message} ->
        raise "restore failed: #{message}"
    end
  end

  @doc """
  Audited SysOp data export for `username` into `output_dir` (ADR 0023).

  Use it for banned users, accounts without qualifying TOTP, or any request
  verified **out of band** (see the SysOp guide). It uses the same archive
  builder and exclusions as self-service export.

  `output_dir` must be owner-only (`chmod 700`) and outside every web root.
  `:reason` is required and logged together with the OS user
  (`$SUDO_USER`/`$USER`, or `:operator`). The user receives a notice.

      bin/baudrate eval 'Baudrate.Release.export_user_data("alice", "/root/exports", reason: "ticket 42")'
  """
  def export_user_data(username, output_dir, opts \\ []) do
    load_app()

    operator =
      Keyword.get(opts, :operator) || System.get_env("SUDO_USER") || System.get_env("USER")

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        Baudrate.DataPortability.sysop_export(username, output_dir,
          operator: operator,
          reason: Keyword.get(opts, :reason),
          base_url: base_url_from_config()
        )
      end)

    case result do
      {:ok, path} -> IO.puts("Export written to #{path} (mode 0600).")
      {:error, reason} -> IO.puts("Export refused: #{inspect(reason)}")
    end

    result
  end

  # Builds the canonical site origin from `BaudrateWeb.Endpoint`'s `:url`
  # config without starting the endpoint. `Federation.base_url/0` calls
  # `Endpoint.url/0`, which reads from the endpoint's `:persistent_term`
  # cache that is only populated once the endpoint is started — so we
  # read the static config here directly.
  # The running endpoint is the authority, because it is what every other URI
  # this instance mints comes from (`Federation.base_url/0`). Release tasks run
  # with only the repo started (see the implementation note on
  # `backfill_ap_ids/1`), so there has to be a fallback — but preferring the
  # endpoint when it *is* up removes a whole class of hazard: the backfill
  # rewrites ids in bulk and publishes them, and two derivations that disagree
  # would stamp a host the site does not answer on.
  # `Endpoint.url/0` reads a cache only populated once the endpoint starts, and
  # it may raise *or* exit depending on how far the supervision tree got —
  # hence both clauses. Under `bin/baudrate eval` neither exists and the static
  # config is the answer; under `bin/baudrate rpc` the endpoint is up and is
  # the authority.
  defp base_url_from_config do
    BaudrateWeb.Endpoint.url()
  rescue
    _ -> base_url_from_static_config()
  catch
    :exit, _ -> base_url_from_static_config()
  end

  defp base_url_from_static_config do
    config = Application.get_env(@app, BaudrateWeb.Endpoint, [])
    url = Keyword.get(config, :url, [])
    scheme = Keyword.get(url, :scheme, "https")
    host = Keyword.get(url, :host, "localhost")
    port = Keyword.get(url, :port)

    cond do
      is_nil(port) -> "#{scheme}://#{host}"
      scheme == "https" and port == 443 -> "#{scheme}://#{host}"
      scheme == "http" and port == 80 -> "#{scheme}://#{host}"
      true -> "#{scheme}://#{host}:#{port}"
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_all_started(:logger)
    Application.load(@app)
  end
end
