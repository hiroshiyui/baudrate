defmodule Baudrate.Retention do
  # Declared before the moduledoc so it can interpolate them: the numbers
  # appeared as literals there, and changing a period would have left the
  # documentation quietly describing the old one.
  @timeline_days 90
  @announce_days 180
  @deleted_days 90
  @batch 500

  @moduledoc """
  Deletes what the instance has agreed not to keep (Phase 2F, P2-D4).

  Three passes, run hourly from `Baudrate.Auth.SessionCleaner` and safe to run
  by hand:

  - **Timeline items** older than #{@timeline_days} days that nobody touched. The
    fediverse timeline is a stream, and the originals stay on the servers that
    published them, so a row here is a cache. An item somebody liked, boosted
    or replied to is kept, and so is one a report points at.
  - **Announce records** older than #{@announce_days} days. These track that a remote
    actor boosted something; `Federation.count_announces/1` reads them for a
    boost count, which therefore drifts down on content this old. That was
    accepted: the alternative is a table that only grows.
  - **Soft-deleted articles and comments** whose `deleted_at` is more than
    #{@deleted_days} days old, which is the evidence window a closed report's copy lives
    for (P1-D6). Nothing a report references is deleted, whatever its age.

  ## What the cutoffs measure

  Timeline items are aged by `inserted_at`, not `published_at`. `published_at`
  comes from the remote object and a peer can set it to anything: a date far
  in the future would keep a row forever, and the past would drop it the hour
  it arrived. `inserted_at` is ours.

  ## Why a reported row is never purged

  `reports.timeline_item_id`, `article_id` and `comment_id` are all
  `nilify_all`, so deleting the subject of a report silently empties the
  report's pointer rather than refusing. Reports are never deleted, so this
  keeps a small set of rows indefinitely — the alternative is a moderation
  record whose subject cannot be read, which is worse than a table slightly
  larger than it needs to be.

  ## Files

  Deleting an article or comment cascades to its image rows, which would leave
  the files on disk with nothing pointing at them — `SessionCleaner`'s orphan
  sweeps find images whose row has no parent, not files whose row is gone. So
  the paths are collected before the delete and removed afterwards.
  """

  import Ecto.Query
  require Logger

  alias Baudrate.Content.{Article, ArticleImage, Comment, CommentImage}
  alias Baudrate.Federation.{Announce, TimelineItem, TimelineItemBoost}
  alias Baudrate.Federation.{TimelineItemLike, TimelineItemReply}
  alias Baudrate.Moderation.Report
  alias Baudrate.Repo

  @type counts :: %{
          timeline_items: non_neg_integer(),
          announces: non_neg_integer(),
          articles: non_neg_integer(),
          comments: non_neg_integer(),
          files: non_neg_integer()
        }

  @doc """
  Runs every pass and returns what each one removed.

  Options:

    * `:dry_run` — count what would go without deleting anything.
    * `:batch` — rows per pass (default #{@batch}); a smaller batch holds
      shorter locks on a busy instance. Timeline items and announces loop
      until nothing is left; the soft-deleted pass takes one batch per run,
      so a large backlog drains over several hours.
    * `:now` — the clock, for tests.
  """
  @spec run(keyword()) :: counts()
  def run(opts \\ []) do
    counts = %{
      timeline_items: purge_timeline_items(opts),
      announces: purge_announces(opts),
      articles: 0,
      comments: 0,
      files: 0
    }

    {articles, comments, files} = purge_soft_deleted(opts)
    counts = %{counts | articles: articles, comments: comments, files: files}

    log(counts, opts)
    counts
  end

  @doc "Deletes untouched timeline items past the retention period."
  @spec purge_timeline_items(keyword()) :: non_neg_integer()
  def purge_timeline_items(opts \\ []) do
    cutoff = cutoff(opts, @timeline_days)

    from(ti in TimelineItem, where: ti.inserted_at < ^cutoff)
    |> where([ti], not exists(interaction(TimelineItemLike)))
    |> where([ti], not exists(interaction(TimelineItemBoost)))
    |> where([ti], not exists(interaction(TimelineItemReply)))
    |> where([ti], not exists(reported_timeline_item()))
    |> delete_in_batches(opts)
  end

  @doc "Deletes Announce records past the retention period."
  @spec purge_announces(keyword()) :: non_neg_integer()
  def purge_announces(opts \\ []) do
    cutoff = cutoff(opts, @announce_days)

    from(a in Announce, where: a.inserted_at < ^cutoff)
    |> delete_in_batches(opts)
  end

  @doc """
  Hard-deletes articles and comments soft-deleted longer ago than the evidence
  window, and removes their images from disk.

  Returns `{articles, comments, files}`.
  """
  @spec purge_soft_deleted(keyword()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def purge_soft_deleted(opts \\ []) do
    cutoff = cutoff(opts, @deleted_days)

    {article_ids, comment_ids} = purgeable_ids(cutoff, opts)

    # Comments CASCADE with their article, so the rows and files that go are
    # not only the ones selected above — collect them before the delete.
    cascaded = cascaded_comment_ids(article_ids, comment_ids)

    paths =
      image_paths(ArticleImage, :article_id, article_ids) ++
        image_paths(CommentImage, :comment_id, comment_ids ++ cascaded)

    if Keyword.get(opts, :dry_run, false) do
      {length(article_ids), length(comment_ids) + length(cascaded), length(paths)}
    else
      direct = delete_by_id(Comment, comment_ids)
      articles = delete_by_id(Article, article_ids)
      files = remove_files(paths)

      # `cascaded` went with the articles rather than through `delete_by_id`,
      # so add them: an operator reading "comments=1" when twelve were
      # destroyed is being misled about what this ran.
      {articles, direct + length(cascaded), files}
    end
  end

  # --- queries ---

  defp interaction(schema) do
    from(x in schema, where: x.timeline_item_id == parent_as(:target).id, select: 1)
  end

  defp reported_timeline_item do
    from(r in Report, where: r.timeline_item_id == parent_as(:target).id, select: 1)
  end

  defp reported_comment_of_article do
    from(c in Comment,
      join: r in Report,
      on: r.comment_id == c.id,
      where: c.article_id == parent_as(:target).id,
      select: 1
    )
  end

  defp cascaded_comment_ids([], _direct), do: []

  defp cascaded_comment_ids(article_ids, direct) do
    from(c in Comment, where: c.article_id in ^article_ids, select: c.id)
    |> Repo.all()
    |> Enum.reject(&(&1 in direct))
  end

  defp purgeable_ids(cutoff, opts) do
    batch = Keyword.get(opts, :batch, @batch)

    articles =
      from(a in Article,
        as: :target,
        where: not is_nil(a.deleted_at) and a.deleted_at < ^cutoff,
        where:
          not exists(from(r in Report, where: r.article_id == parent_as(:target).id, select: 1)),
        # A comment goes with its article, and `reports.comment_id` is
        # `nilify_all` — so a report on any of its comments protects the
        # article too. Without this the cascade would empty that moderation
        # record instead of the delete refusing, which is exactly what this
        # module promises never happens.
        where: not exists(reported_comment_of_article()),
        select: a.id,
        limit: ^batch
      )
      |> Repo.all()

    comments =
      from(c in Comment,
        as: :target,
        where: not is_nil(c.deleted_at) and c.deleted_at < ^cutoff,
        where:
          not exists(from(r in Report, where: r.comment_id == parent_as(:target).id, select: 1)),
        select: c.id,
        limit: ^batch
      )
      |> Repo.all()

    {articles, comments}
  end

  defp image_paths(_schema, _key, []), do: []

  defp image_paths(schema, key, ids) do
    from(i in schema, where: field(i, ^key) in ^ids, select: i.storage_path)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
  end

  # --- deletion ---

  # `delete_all` with a limit needs the ids first: PostgreSQL has no
  # `DELETE … LIMIT`, and deleting a whole retention backlog in one statement
  # would hold locks for as long as it takes.
  defp delete_in_batches(query, opts) do
    batch = Keyword.get(opts, :batch, @batch)
    query = from(x in query, as: :target)

    if Keyword.get(opts, :dry_run, false) do
      Repo.aggregate(exclude(query, :order_by), :count, :id)
    else
      delete_loop(query, batch, 0)
    end
  end

  defp delete_loop(query, batch, acc) do
    ids = Repo.all(from(x in query, select: x.id, limit: ^batch))

    if ids == [] do
      acc
    else
      {count, _} = Repo.delete_all(from(x in query, where: x.id in ^ids))

      # A batch that deletes nothing would loop forever; stop rather than spin.
      if count == 0, do: acc, else: delete_loop(query, batch, acc + count)
    end
  end

  defp delete_by_id(_schema, []), do: 0

  defp delete_by_id(schema, ids) do
    {count, _} = Repo.delete_all(from(x in schema, where: x.id in ^ids))
    count
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_files(paths) do
    Enum.count(paths, fn path ->
      case File.rm(path) do
        :ok ->
          true

        {:error, :enoent} ->
          false

        {:error, reason} ->
          Logger.warning("retention.file_delete_failed: reason=#{inspect(reason)}")
          false
      end
    end)
  end

  # --- helpers ---

  defp cutoff(opts, days) do
    opts
    |> Keyword.get(:now, DateTime.utc_now())
    |> DateTime.add(-days * 86_400, :second)
  end

  defp log(counts, opts) do
    prefix = if Keyword.get(opts, :dry_run, false), do: "retention: [dry] ", else: "retention: "

    if Enum.any?(Map.values(counts), &(&1 > 0)) do
      Logger.info(
        prefix <>
          "timeline_items=#{counts.timeline_items} announces=#{counts.announces} " <>
          "articles=#{counts.articles} comments=#{counts.comments} files=#{counts.files}"
      )
    end

    :ok
  end
end
