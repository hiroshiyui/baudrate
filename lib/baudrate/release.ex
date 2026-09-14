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
  Backfills missing `ap_id` fields on local articles, polls, and comments.

  ap_id stamping is now part of the same transaction as the insert (since
  v1.8.2), but pre-existing rows from earlier code paths may carry
  `ap_id = nil` if a process crashed between transaction commit and the
  separate post-commit `Repo.update!/1` that stamped them. This task heals
  those rows in place using the canonical-URI scheme `Articles.create_article/3`
  and `Comments.create_comment/2` apply at write time.

  Skipped:
    * Remote rows (`remote_actor_id` non-nil) — those carry the
      originating server's `ap_id` and must not be rewritten.
    * Local rows for which the canonical URI cannot be derived (e.g. a
      local comment whose author was hard-deleted before stamping).

  ## Options

    * `:dry_run` — when true, log what would be stamped without writing.

  Returns a map with `:articles`, `:polls`, and `:comments` keys, each a
  `{found, stamped}` tuple.

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
    rows =
      from(p in Poll,
        join: a in Article,
        on: a.id == p.article_id,
        where: is_nil(p.ap_id) and is_nil(a.remote_actor_id) and not is_nil(a.slug),
        select: %{id: p.id, article_ap_id: a.ap_id, slug: a.slug}
      )
      |> Repo.all()

    Logger.info("backfill_ap_ids: found #{length(rows)} local poll(s) with nil ap_id")

    stamped =
      Enum.reduce(rows, 0, fn %{id: id, article_ap_id: article_ap_id, slug: slug}, acc ->
        article_uri = article_ap_id || "#{base}/ap/articles/#{slug}"
        ap_id = "#{article_uri}#poll"
        stamp_row(Poll, id, [ap_id: ap_id], "poll", dry_run, acc)
      end)

    {length(rows), stamped}
  end

  defp backfill_comments(dry_run, base) do
    rows =
      from(c in Comment,
        join: a in Article,
        on: a.id == c.article_id,
        join: u in User,
        on: u.id == c.user_id,
        where: is_nil(c.ap_id) and is_nil(c.remote_actor_id),
        select: %{id: c.id, username: u.username, slug: a.slug}
      )
      |> Repo.all()

    Logger.info("backfill_ap_ids: found #{length(rows)} local comment(s) with nil ap_id")

    stamped =
      Enum.reduce(rows, 0, fn %{id: id, username: username, slug: slug}, acc ->
        ap_id = "#{base}/ap/users/#{username}#note-#{id}"
        url = "#{base}/articles/#{slug}#comment-#{id}"
        stamp_row(Comment, id, [ap_id: ap_id, url: url], "comment", dry_run, acc)
      end)

    {length(rows), stamped}
  end

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
  defp base_url_from_config do
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
