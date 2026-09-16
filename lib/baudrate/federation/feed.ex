defmodule Baudrate.Federation.Feed do
  @moduledoc """
  Feed item management and interactions for the Federation context.

  Handles:

  - Feed item creation and soft-deletion (remote Create/Announce activities
    stored as `FeedItem` records).
  - Paginated feed queries merging remote items, local articles from followed
    users, and comment participation threads.
  - Feed item replies (local `FeedItemReply` records with AP delivery).
  - Like and boost toggles on feed items, with AP Like/Announce delivery.
  """

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Content.{Board, BoardArticle, Filters, Markdown}
  alias Baudrate.Repo

  alias Baudrate.Federation.{
    DomainBlockCache,
    FeedItem,
    FeedItemBoost,
    FeedItemLike,
    FeedItemReply,
    Follows,
    Publisher,
    RemoteActor,
    ReplyImages,
    UserFollow
  }

  alias Baudrate.Federation.PubSub, as: FederationPubSub

  @state_accepted "accepted"
  @feed_per_page 20

  @doc """
  Creates a feed item and broadcasts to all local followers of the source actor.

  Returns `{:ok, %FeedItem{}}` or `{:error, changeset}`.
  """
  def create_feed_item(attrs) do
    case %FeedItem{} |> FeedItem.changeset(attrs) |> Repo.insert() do
      {:ok, feed_item} ->
        remote_actor_id = feed_item.remote_actor_id

        for user_id <- Follows.local_followers_of_remote_actor(remote_actor_id) do
          FederationPubSub.broadcast_to_user_feed(
            user_id,
            :feed_item_created,
            %{feed_item_id: feed_item.id}
          )
        end

        {:ok, feed_item}

      error ->
        error
    end
  end

  @doc """
  Lists paginated feed items for a user.

  Includes the user's own articles, remote feed items and local articles
  from accepted follows, and comments on articles the user authored or
  previously commented on (including the user's own comments). Excludes
  soft-deleted items and items from blocked/muted actors. Local article
  items include a `comment_count` key; comment items include the comment
  with preloaded `:user` and `article: :user`.

  Returns `%{items: [...], total: n, page: n, per_page: n, total_pages: n}`.
  """
  def list_feed_items(user, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @feed_per_page)
    offset = (page - 1) * per_page

    {hidden_user_ids, hidden_ap_ids} = Auth.hidden_ids(user)

    remote_query =
      from(fi in FeedItem,
        join: uf in UserFollow,
        on:
          (fi.activity_type == "Create" and uf.remote_actor_id == fi.remote_actor_id) or
            (fi.activity_type == "Announce" and uf.remote_actor_id == fi.boosted_by_actor_id),
        join: ra in RemoteActor,
        on: ra.id == fi.remote_actor_id,
        where: uf.user_id == ^user.id and uf.state == @state_accepted,
        where: is_nil(fi.deleted_at),
        # An instance block hides what the domain already sent (ADR 0030).
        # Blocking severs the follows, so most of this disappears anyway — but
        # a boost carries an author the follower never followed, and that
        # author can be on the blocked domain while the booster is not.
        where: fi.remote_actor_id not in subquery(Filters.hidden_actor_ids()),
        where:
          is_nil(fi.boosted_by_actor_id) or
            fi.boosted_by_actor_id not in subquery(Filters.hidden_actor_ids())
      )

    remote_query =
      if hidden_ap_ids != [] do
        from([fi, _uf, ra] in remote_query, where: ra.ap_id not in ^hidden_ap_ids)
      else
        remote_query
      end

    # A followed user's articles are only feed-visible when the follower could
    # open them on the board: board-less (remote import) articles are public;
    # otherwise one of the article's boards must be at or below the
    # follower's role. Without this, following an admin surfaced titles,
    # digests and images from admin-only boards in the follower's feed.
    allowed_roles = Filters.allowed_view_roles(user)

    local_query =
      from(a in Baudrate.Content.Article,
        as: :article,
        left_join: uf in UserFollow,
        on:
          uf.followed_user_id == a.user_id and uf.user_id == ^user.id and
            uf.state == @state_accepted,
        where: a.user_id == ^user.id or not is_nil(uf.id),
        where: is_nil(a.deleted_at),
        where:
          a.user_id == ^user.id or
            not exists(
              from(ba in BoardArticle, where: ba.article_id == parent_as(:article).id, select: 1)
            ) or
            exists(
              from(ba in BoardArticle,
                join: b in Board,
                on: b.id == ba.board_id,
                where:
                  ba.article_id == parent_as(:article).id and
                    b.min_role_to_view in ^allowed_roles,
                select: 1
              )
            )
      )

    local_query =
      if hidden_user_ids != [] do
        from(a in local_query, where: a.user_id not in ^hidden_user_ids)
      else
        local_query
      end

    participated_subquery =
      from(oc in Baudrate.Content.Comment,
        where: oc.article_id == parent_as(:article).id and oc.user_id == ^user.id,
        select: 1
      )

    comment_query =
      from(c in Baudrate.Content.Comment,
        join: a in Baudrate.Content.Article,
        as: :article,
        on: a.id == c.article_id,
        where: a.user_id == ^user.id or exists(participated_subquery),
        where: is_nil(c.deleted_at) and is_nil(a.deleted_at)
      )

    comment_query =
      if hidden_user_ids != [] do
        from([c, _a] in comment_query, where: c.user_id not in ^hidden_user_ids)
      else
        comment_query
      end

    {remote_total, local_total, comment_total} =
      count_feed_totals(user.id, hidden_user_ids, hidden_ap_ids, allowed_roles)

    total = remote_total + local_total + comment_total

    remote_items =
      from([fi, _uf, ra] in remote_query,
        order_by: [desc: fi.published_at, desc: fi.id],
        limit: ^(offset + per_page),
        preload: [:remote_actor, :boosted_by_actor]
      )
      |> Repo.all()
      |> Enum.map(fn fi ->
        %{source: :remote, feed_item: fi, sorted_at: fi.published_at}
      end)

    local_articles =
      from(a in local_query,
        order_by: [desc: a.inserted_at, desc: a.id],
        limit: ^(offset + per_page),
        preload: [:user, :article_images, boards: []]
      )
      |> Repo.all()

    local_article_ids = Enum.map(local_articles, & &1.id)

    comment_counts =
      if local_article_ids != [] do
        from(c in Baudrate.Content.Comment,
          where: c.article_id in ^local_article_ids and is_nil(c.deleted_at),
          group_by: c.article_id,
          select: {c.article_id, count(c.id)}
        )
        |> Repo.all()
        |> Map.new()
      else
        %{}
      end

    local_items =
      Enum.map(local_articles, fn article ->
        %{
          source: :local,
          article: article,
          comment_count: Map.get(comment_counts, article.id, 0),
          sorted_at: article.inserted_at
        }
      end)

    comment_items =
      from([c, _a] in comment_query,
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: ^(offset + per_page),
        preload: [:user, :remote_actor, article: :user]
      )
      |> Repo.all()
      |> Enum.map(fn c ->
        %{source: :local_comment, comment: c, sorted_at: c.inserted_at}
      end)

    items =
      (remote_items ++ local_items ++ comment_items)
      |> Enum.sort_by(& &1.sorted_at, {:desc, DateTime})
      |> Enum.drop(offset)
      |> Enum.take(per_page)

    total_pages = max(ceil(total / per_page), 1)

    %{
      items: items,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  @doc """
  Returns a feed item by its ActivityPub ID, or nil.
  """
  def get_feed_item_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.one(from(fi in FeedItem, where: fi.ap_id == ^ap_id))
  end

  @doc """
  Soft-deletes a feed item by AP ID, scoped to a remote actor.

  Returns `{count, nil}`.
  """
  def soft_delete_feed_item_by_ap_id(ap_id, remote_actor_id) when is_binary(ap_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(fi in FeedItem,
      where:
        fi.ap_id == ^ap_id and fi.remote_actor_id == ^remote_actor_id and is_nil(fi.deleted_at)
    )
    |> Repo.update_all(set: [deleted_at: now])
  end

  @doc """
  Bulk soft-deletes all feed items from a given remote actor.

  Used when a remote actor is deleted. Returns `{count, nil}`.
  """
  def cleanup_feed_items_for_actor(remote_actor_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(fi in FeedItem,
      where: fi.remote_actor_id == ^remote_actor_id and is_nil(fi.deleted_at)
    )
    |> Repo.update_all(set: [deleted_at: now])
  end

  @doc """
  Repoints feed items from a migrated remote actor to its new identity.

  Called after a verified inbound `Move`. Feed membership is a query-time join
  on `user_follows`, so migrating the follow without migrating the items would
  make every item the actor had already published vanish from its followers'
  feeds — and, because `feed_item_accessible?/2` resolves the same source
  actor, become un-likeable, un-boostable, un-repliable, and un-forwardable.

  Both roles are repointed: `remote_actor_id` (the author of a `Create`, or the
  original author of an `Announce`) and `boosted_by_actor_id` (the booster,
  which is what `Announce` feed membership keys on).

  Only feed items move. Articles and comments keep their original
  `remote_actor_id`: they are board content with their own permalinks and
  `ap_id`s, and rewriting their authorship would retroactively reattribute
  posts that remain published under the old actor on its own instance.

  Returns `{create_count, announce_count}`.
  """
  @spec migrate_feed_items(integer(), integer()) :: {non_neg_integer(), non_neg_integer()}
  def migrate_feed_items(old_actor_id, new_actor_id)
      when is_integer(old_actor_id) and is_integer(new_actor_id) do
    {authored, _} =
      from(fi in FeedItem, where: fi.remote_actor_id == ^old_actor_id)
      |> Repo.update_all(set: [remote_actor_id: new_actor_id])

    {boosted, _} =
      from(fi in FeedItem, where: fi.boosted_by_actor_id == ^old_actor_id)
      |> Repo.update_all(set: [boosted_by_actor_id: new_actor_id])

    {authored, boosted}
  end

  @doc """
  Creates a reply to a remote feed item and schedules federation delivery.

  Renders the body as Markdown → HTML, generates an AP ID, inserts the
  `FeedItemReply` record, and enqueues a `Create(Note)` activity for
  delivery to the remote actor's inbox and the replying user's AP followers.

  The feed item must be reachable from the user's feed
  (`feed_item_accessible?/2`) — consistent with liking and boosting. Callers
  resolve the item from a client-supplied ID, so replying to a soft-deleted
  or non-followed item is refused here at the context boundary rather than
  federating a `Create(Note)` to an unrelated remote inbox.

  Returns `{:ok, %FeedItemReply{}}`, `{:error, :not_found}`,
  `{:error, :account_moved}` (ADR 0025), `{:error, :blocked}` (the user has
  blocked the item's author), or `{:error, changeset}`.
  """
  def create_feed_item_reply(feed_item, user, body, opts \\ []) do
    # A moved, silenced or suspended account cannot reply (ADR 0029).
    gate = Baudrate.Auth.ensure_can_interact(user)

    cond do
      not feed_item_accessible?(user, feed_item) -> {:error, :not_found}
      gate != :ok -> gate
      Baudrate.Auth.blocked_with_author?(user.id, feed_item) -> {:error, :blocked}
      true -> do_create_feed_item_reply(feed_item, user, body, opts)
    end
  end

  defp do_create_feed_item_reply(feed_item, user, body, opts) do
    ap_id =
      "#{Baudrate.Federation.actor_uri(:user, user.username)}#feed-reply-#{Ecto.UUID.generate()}"

    body_html = Markdown.to_html(body)
    image_ids = Keyword.get(opts, :image_ids, [])

    attrs = %{
      feed_item_id: feed_item.id,
      user_id: user.id,
      body: body,
      body_html: body_html,
      ap_id: ap_id
    }

    case %FeedItemReply{} |> FeedItemReply.changeset(attrs) |> Repo.insert() do
      {:ok, reply} ->
        if image_ids != [] do
          ReplyImages.associate_reply_images(reply.id, image_ids, user.id)
        end

        Baudrate.Federation.schedule_federation_task(fn ->
          reply = Repo.preload(reply, :images)
          Publisher.publish_feed_item_reply(reply, feed_item)
        end)

        {:ok, reply}

      error ->
        error
    end
  end

  @doc """
  Lists replies for a feed item, ordered by insertion time ascending.

  Preloads the `:user` association (with `:role`).
  """
  def list_feed_item_replies(feed_item_id) do
    from(r in FeedItemReply,
      where: r.feed_item_id == ^feed_item_id,
      order_by: [asc: r.inserted_at, asc: r.id],
      preload: [:images, user: :role]
    )
    |> Repo.all()
  end

  @doc """
  Batch-counts replies grouped by feed item ID.

  Accepts a list of feed item IDs and returns a map of
  `%{feed_item_id => count}`.
  """
  def count_feed_item_replies(feed_item_ids) when is_list(feed_item_ids) do
    if feed_item_ids == [] do
      %{}
    else
      from(r in FeedItemReply,
        where: r.feed_item_id in ^feed_item_ids,
        group_by: r.feed_item_id,
        select: {r.feed_item_id, count(r.id)}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @doc """
  Toggles a like on a remote feed item — creates if not exists, removes if exists.
  Sends AP Like/Undo(Like) to the remote actor's inbox.
  """
  def toggle_feed_item_like(user, feed_item_id) do
    case Repo.get(FeedItem, feed_item_id) do
      nil ->
        {:error, :not_found}

      feed_item ->
        if not feed_item_accessible?(user, feed_item) do
          {:error, :not_found}
        else
          do_toggle_feed_item_like(user, feed_item)
        end
    end
  end

  @doc """
  Returns a MapSet of feed item IDs that the given user has liked.
  """
  def feed_item_likes_by_user(_user_id, []), do: MapSet.new()

  def feed_item_likes_by_user(user_id, feed_item_ids) do
    from(l in FeedItemLike,
      where: l.user_id == ^user_id and l.feed_item_id in ^feed_item_ids,
      select: l.feed_item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Toggles a boost on a remote feed item — creates if not exists, removes if exists.
  Sends AP Announce/Undo(Announce) to the remote actor's inbox.
  """
  def toggle_feed_item_boost(user, feed_item_id) do
    case Repo.get(FeedItem, feed_item_id) do
      nil ->
        {:error, :not_found}

      feed_item ->
        if not feed_item_accessible?(user, feed_item) do
          {:error, :not_found}
        else
          do_toggle_feed_item_boost(user, feed_item)
        end
    end
  end

  @doc """
  Returns a MapSet of feed item IDs that the given user has boosted.
  """
  def feed_item_boosts_by_user(_user_id, []), do: MapSet.new()

  def feed_item_boosts_by_user(user_id, feed_item_ids) do
    from(b in FeedItemBoost,
      where: b.user_id == ^user_id and b.feed_item_id in ^feed_item_ids,
      select: b.feed_item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # --- Private ---

  defp ensure_author_not_blocked(user, feed_item) do
    if Baudrate.Auth.blocked_with_author?(user.id, feed_item),
      do: {:error, :blocked},
      else: :ok
  end

  defp do_toggle_feed_item_like(user, feed_item) do
    feed_item_id = feed_item.id

    case Repo.get_by(FeedItemLike, user_id: user.id, feed_item_id: feed_item_id) do
      nil ->
        # A restricted account and a blocked author are the same shape here:
        # both can undo an earlier like, not add a new one (ADR 0029).
        result =
          with :ok <- Baudrate.Auth.ensure_can_interact(user),
               :ok <- ensure_author_not_blocked(user, feed_item) do
            %FeedItemLike{}
            |> FeedItemLike.changeset(%{user_id: user.id, feed_item_id: feed_item_id})
            |> Repo.insert()
          end

        with {:ok, like} <- result do
          ap_id =
            Baudrate.Federation.actor_uri(:user, user.username) <>
              "#feed-like-#{like.id}"

          like =
            like
            |> Ecto.Changeset.change(ap_id: ap_id)
            |> Repo.update!()

          Baudrate.Federation.schedule_federation_task(fn ->
            Publisher.publish_feed_item_liked(user, feed_item)
          end)

          {:ok, like}
        end

      like ->
        like_ap_id = like.ap_id
        Repo.delete!(like)

        Baudrate.Federation.schedule_federation_task(fn ->
          Publisher.publish_feed_item_unliked(user, feed_item, like_ap_id)
        end)

        {:ok, :removed}
    end
  end

  defp do_toggle_feed_item_boost(user, feed_item) do
    feed_item_id = feed_item.id

    case Repo.get_by(FeedItemBoost, user_id: user.id, feed_item_id: feed_item_id) do
      nil ->
        # A restricted account and a blocked author are the same shape here:
        # both can undo an earlier boost, not add a new one (ADR 0029).
        result =
          with :ok <- Baudrate.Auth.ensure_can_interact(user),
               :ok <- ensure_author_not_blocked(user, feed_item) do
            %FeedItemBoost{}
            |> FeedItemBoost.changeset(%{user_id: user.id, feed_item_id: feed_item_id})
            |> Repo.insert()
          end

        with {:ok, boost} <- result do
          ap_id =
            Baudrate.Federation.actor_uri(:user, user.username) <>
              "#feed-announce-#{boost.id}"

          boost =
            boost
            |> Ecto.Changeset.change(ap_id: ap_id)
            |> Repo.update!()

          Baudrate.Federation.schedule_federation_task(fn ->
            Publisher.publish_feed_item_boosted(user, feed_item)
          end)

          {:ok, boost}
        end

      boost ->
        boost_ap_id = boost.ap_id
        Repo.delete!(boost)

        Baudrate.Federation.schedule_federation_task(fn ->
          Publisher.publish_feed_item_unboosted(user, feed_item, boost_ap_id)
        end)

        {:ok, :removed}
    end
  end

  @doc """
  Returns true if `feed_item` is reachable from `user`'s feed.

  Mirrors the membership conditions of `list_feed_items/2` exactly: the item
  must not be soft-deleted, and the user must have an `accepted` follow on
  the item's **source** actor — the author for `Create` activities, or the
  booster for `Announce` activities (for a boost, `remote_actor_id` is the
  original author, whom the user need not follow).

  `feed_items` rows are global — feed membership is a query-time join on
  `user_follows` — so every entry point that resolves a feed item from a
  client-supplied ID (like, boost, reply, forward-to-board) must call this
  before acting on it.
  """
  @spec feed_item_accessible?(map(), %FeedItem{}) :: boolean()
  def feed_item_accessible?(_user, %FeedItem{deleted_at: deleted_at}) when not is_nil(deleted_at),
    do: false

  def feed_item_accessible?(user, %FeedItem{} = feed_item) do
    source_actor_id =
      case feed_item.activity_type do
        "Announce" -> feed_item.boosted_by_actor_id
        _ -> feed_item.remote_actor_id
      end

    not is_nil(source_actor_id) and
      Repo.exists?(
        from(uf in UserFollow,
          where:
            uf.user_id == ^user.id and
              uf.remote_actor_id == ^source_actor_id and
              uf.state == @state_accepted
        )
      )
  end

  # Counts remote feed items, local articles, and comments in a single SQL
  # round-trip using 3 scalar subqueries. The conditions exactly mirror the
  # Ecto queries in `list_feed_items/2`.
  defp count_feed_totals(user_id, hidden_user_ids, hidden_ap_ids, allowed_roles) do
    hidden_ap_ids_param = if hidden_ap_ids == [], do: nil, else: hidden_ap_ids
    hidden_user_ids_param = if hidden_user_ids == [], do: nil, else: hidden_user_ids

    # Instance-level hiding, in the same shape as `Filters.hidden_actor_ids/0`.
    # The domains are a parameter, never interpolated. An empty array gives the
    # right answer in both modes: nothing blocked, or everything not allowed.
    {mode, domains} = DomainBlockCache.config()
    blocklist_mode = mode == :blocklist
    domains_param = MapSet.to_list(domains)

    %{rows: [[remote_total, local_total, comment_total]]} =
      Repo.query!(
        """
        SELECT
          (SELECT count(*) FROM feed_items fi
             JOIN user_follows uf ON (
               (fi.activity_type = 'Create' AND uf.remote_actor_id = fi.remote_actor_id) OR
               (fi.activity_type = 'Announce' AND uf.remote_actor_id = fi.boosted_by_actor_id)
             )
             JOIN remote_actors ra ON ra.id = fi.remote_actor_id
             WHERE uf.user_id = $1 AND uf.state = 'accepted'
               AND fi.deleted_at IS NULL
               AND ($2::text[] IS NULL OR ra.ap_id != ALL($2))
               AND NOT EXISTS (
                 SELECT 1 FROM remote_actors hra
                 WHERE hra.id IN (fi.remote_actor_id, fi.boosted_by_actor_id)
                   AND (CASE WHEN $5::boolean
                             THEN hra.domain = ANY($6::text[])
                             ELSE hra.domain <> ALL($6::text[]) END))),
          (SELECT count(*) FROM articles a
             LEFT JOIN user_follows uf ON uf.followed_user_id = a.user_id
               AND uf.user_id = $1 AND uf.state = 'accepted'
             WHERE (a.user_id = $1 OR uf.id IS NOT NULL)
               AND a.deleted_at IS NULL
               AND ($3::bigint[] IS NULL OR a.user_id != ALL($3))
               AND (a.user_id = $1
                    OR NOT EXISTS (SELECT 1 FROM board_articles ba WHERE ba.article_id = a.id)
                    OR EXISTS (SELECT 1 FROM board_articles ba JOIN boards b ON b.id = ba.board_id
                               WHERE ba.article_id = a.id AND b.min_role_to_view = ANY($4::text[])))),
          (SELECT count(*) FROM comments c
             JOIN articles a ON a.id = c.article_id
             WHERE (a.user_id = $1 OR EXISTS(
               SELECT 1 FROM comments oc WHERE oc.article_id = a.id AND oc.user_id = $1))
               AND c.deleted_at IS NULL AND a.deleted_at IS NULL
               AND ($3::bigint[] IS NULL OR c.user_id != ALL($3)))
        """,
        [
          user_id,
          hidden_ap_ids_param,
          hidden_user_ids_param,
          allowed_roles,
          blocklist_mode,
          domains_param
        ]
      )

    {remote_total, local_total, comment_total}
  end
end
