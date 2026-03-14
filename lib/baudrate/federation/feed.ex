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
  alias Baudrate.Content.Markdown
  alias Baudrate.Repo

  alias Baudrate.Federation.{
    FeedItem,
    FeedItemBoost,
    FeedItemLike,
    FeedItemReply,
    Follows,
    Publisher,
    RemoteActor,
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
        where: is_nil(fi.deleted_at)
      )

    remote_query =
      if hidden_ap_ids != [] do
        from([fi, _uf, ra] in remote_query, where: ra.ap_id not in ^hidden_ap_ids)
      else
        remote_query
      end

    local_query =
      from(a in Baudrate.Content.Article,
        left_join: uf in UserFollow,
        on:
          uf.followed_user_id == a.user_id and uf.user_id == ^user.id and
            uf.state == @state_accepted,
        where: a.user_id == ^user.id or not is_nil(uf.id),
        where: is_nil(a.deleted_at)
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
      count_feed_totals(user.id, hidden_user_ids, hidden_ap_ids)

    total = remote_total + local_total + comment_total

    remote_items =
      from([fi, _uf, ra] in remote_query,
        order_by: [desc: fi.published_at],
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
  Creates a reply to a remote feed item and schedules federation delivery.

  Renders the body as Markdown → HTML, generates an AP ID, inserts the
  `FeedItemReply` record, and enqueues a `Create(Note)` activity for
  delivery to the remote actor's inbox and the replying user's AP followers.

  Returns `{:ok, %FeedItemReply{}}` or `{:error, changeset}`.
  """
  def create_feed_item_reply(feed_item, user, body) do
    ap_id =
      "#{Baudrate.Federation.actor_uri(:user, user.username)}#feed-reply-#{System.unique_integer([:positive])}"

    body_html = Markdown.to_html(body)

    attrs = %{
      feed_item_id: feed_item.id,
      user_id: user.id,
      body: body,
      body_html: body_html,
      ap_id: ap_id
    }

    case %FeedItemReply{} |> FeedItemReply.changeset(attrs) |> Repo.insert() do
      {:ok, reply} ->
        Baudrate.Federation.schedule_federation_task(fn ->
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
      preload: [user: :role]
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

  defp do_toggle_feed_item_like(user, feed_item) do
    feed_item_id = feed_item.id

    case Repo.get_by(FeedItemLike, user_id: user.id, feed_item_id: feed_item_id) do
      nil ->
        result =
          %FeedItemLike{}
          |> FeedItemLike.changeset(%{user_id: user.id, feed_item_id: feed_item_id})
          |> Repo.insert()

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
        result =
          %FeedItemBoost{}
          |> FeedItemBoost.changeset(%{user_id: user.id, feed_item_id: feed_item_id})
          |> Repo.insert()

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

  # Returns true if the user follows the remote actor who created the feed item.
  defp feed_item_accessible?(user, feed_item) do
    Repo.exists?(
      from(uf in UserFollow,
        where:
          uf.user_id == ^user.id and
            uf.remote_actor_id == ^feed_item.remote_actor_id and
            uf.state == "accepted"
      )
    )
  end

  # Counts remote feed items, local articles, and comments in a single SQL
  # round-trip using 3 scalar subqueries. The conditions exactly mirror the
  # Ecto queries in `list_feed_items/2`.
  defp count_feed_totals(user_id, hidden_user_ids, hidden_ap_ids) do
    hidden_ap_ids_param = if hidden_ap_ids == [], do: nil, else: hidden_ap_ids
    hidden_user_ids_param = if hidden_user_ids == [], do: nil, else: hidden_user_ids

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
               AND ($2::text[] IS NULL OR ra.ap_id != ALL($2))),
          (SELECT count(*) FROM articles a
             LEFT JOIN user_follows uf ON uf.followed_user_id = a.user_id
               AND uf.user_id = $1 AND uf.state = 'accepted'
             WHERE (a.user_id = $1 OR uf.id IS NOT NULL)
               AND a.deleted_at IS NULL
               AND ($3::bigint[] IS NULL OR a.user_id != ALL($3))),
          (SELECT count(*) FROM comments c
             JOIN articles a ON a.id = c.article_id
             WHERE (a.user_id = $1 OR EXISTS(
               SELECT 1 FROM comments oc WHERE oc.article_id = a.id AND oc.user_id = $1))
               AND c.deleted_at IS NULL AND a.deleted_at IS NULL
               AND ($3::bigint[] IS NULL OR c.user_id != ALL($3)))
        """,
        [user_id, hidden_ap_ids_param, hidden_user_ids_param]
      )

    {remote_total, local_total, comment_total}
  end
end
