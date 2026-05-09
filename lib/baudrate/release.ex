defmodule Baudrate.Release do
  @moduledoc """
  Release tasks for running migrations, rollbacks, and one-shot data
  maintenance in production.

  Mix tasks aren't available inside an OTP release; invoke these via
  `bin/baudrate eval` or `bin/baudrate rpc`:

      bin/baudrate eval "Baudrate.Release.migrate"
      bin/baudrate eval "Baudrate.Release.rollback(Baudrate.Repo, 20240101000000)"
      bin/baudrate eval "Baudrate.Release.backfill_ap_ids()"
      bin/baudrate eval "Baudrate.Release.backfill_ap_ids(dry_run: true)"
  """

  import Ecto.Query

  require Logger

  alias Baudrate.Content.{Article, Comment, Poll}
  alias Baudrate.Federation
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
  """
  @spec backfill_ap_ids(keyword()) :: %{
          articles: {non_neg_integer(), non_neg_integer()},
          polls: {non_neg_integer(), non_neg_integer()},
          comments: {non_neg_integer(), non_neg_integer()}
        }
  def backfill_ap_ids(opts \\ []) do
    load_app()
    Application.ensure_all_started(@app)

    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      Logger.info("backfill_ap_ids: dry run — no changes will be written")
    end

    articles = backfill_articles(dry_run)
    polls = backfill_polls(dry_run)
    comments = backfill_comments(dry_run)

    {a_total, a_stamped} = articles
    {p_total, p_stamped} = polls
    {c_total, c_stamped} = comments

    Logger.info(
      "backfill_ap_ids: complete — articles=#{a_stamped}/#{a_total} polls=#{p_stamped}/#{p_total} comments=#{c_stamped}/#{c_total}"
    )

    %{articles: articles, polls: polls, comments: comments}
  end

  # --- Articles ---

  defp backfill_articles(dry_run) do
    rows =
      from(a in Article,
        where: is_nil(a.ap_id) and is_nil(a.remote_actor_id) and not is_nil(a.slug),
        select: %{id: a.id, slug: a.slug}
      )
      |> Repo.all()

    Logger.info("backfill_ap_ids: found #{length(rows)} local article(s) with nil ap_id")

    stamped =
      Enum.reduce(rows, 0, fn %{id: id, slug: slug}, acc ->
        ap_id = Federation.actor_uri(:article, slug)
        stamp_row(Article, id, [ap_id: ap_id], "article", dry_run, acc)
      end)

    {length(rows), stamped}
  end

  # --- Polls ---

  defp backfill_polls(dry_run) do
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
        article_uri = article_ap_id || Federation.actor_uri(:article, slug)
        ap_id = "#{article_uri}#poll"
        stamp_row(Poll, id, [ap_id: ap_id], "poll", dry_run, acc)
      end)

    {length(rows), stamped}
  end

  # --- Comments ---

  defp backfill_comments(dry_run) do
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
        ap_id = "#{Federation.actor_uri(:user, username)}#note-#{id}"
        url = "#{Federation.base_url()}/articles/#{slug}#comment-#{id}"
        stamp_row(Comment, id, [ap_id: ap_id, url: url], "comment", dry_run, acc)
      end)

    {length(rows), stamped}
  end

  # --- Stamp helper ---

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

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
