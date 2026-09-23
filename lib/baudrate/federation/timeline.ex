defmodule Baudrate.Federation.Timeline do
  @moduledoc """
  Timeline item management and interactions for the Federation context.

  Handles:

  - Timeline item creation and soft-deletion (remote Create/Announce activities
    stored as `TimelineItem` records).
  - Paginated timeline queries merging remote items, local articles from followed
    users, and comment participation threads.
  - Timeline item replies (local `TimelineItemReply` records with AP delivery).
  - Like and boost toggles on timeline items, with AP Like/Announce delivery.
  """

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Content.{Board, BoardArticle, Filters, Markdown}
  alias Baudrate.Repo

  alias Baudrate.Federation.{
    DomainBlockCache,
    TimelineItem,
    TimelineItemBoost,
    TimelineItemLike,
    TimelineItemReply,
    Follows,
    Publisher,
    RemoteActor,
    ReplyImages,
    UserFollow
  }

  alias Baudrate.Federation.PubSub, as: FederationPubSub

  @state_accepted "accepted"
  @timeline_per_page 20

  @doc """
  Creates a timeline item and broadcasts to all local followers of the source actor.

  Returns `{:ok, %TimelineItem{}}` or `{:error, changeset}`.
  """
  def create_timeline_item(attrs) do
    case %TimelineItem{} |> TimelineItem.changeset(attrs) |> Repo.insert() do
      {:ok, timeline_item} ->
        remote_actor_id = timeline_item.remote_actor_id

        for user_id <- Follows.local_followers_of_remote_actor(remote_actor_id) do
          FederationPubSub.broadcast_to_user_timeline(
            user_id,
            :timeline_item_created,
            %{timeline_item_id: timeline_item.id}
          )
        end

        {:ok, timeline_item}

      error ->
        error
    end
  end

  @doc """
  Lists paginated timeline items for a user.

  Includes the user's own articles, remote timeline items and local articles
  from accepted follows, and comments on articles the user authored or
  previously commented on (including the user's own comments). Excludes
  soft-deleted items and items from blocked/muted actors. Local article
  items include a `comment_count` key; comment items include the comment
  with preloaded `:user` and `article: :user`.

  Returns `%{items: [...], total: n, page: n, per_page: n, total_pages: n}`.
  """
  def list_timeline_items(user, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @timeline_per_page)
    offset = (page - 1) * per_page

    {hidden_user_ids, hidden_ap_ids} = Auth.hidden_ids(user)
    # Servers the member muted as a whole (ADR 0073), filtered by domain.
    muted_domains = Auth.muted_domains(user)

    remote_query =
      from(fi in TimelineItem,
        join: uf in UserFollow,
        on:
          (fi.activity_type == "Create" and uf.remote_actor_id == fi.remote_actor_id) or
            (fi.activity_type == "Announce" and uf.remote_actor_id == fi.boosted_by_actor_id),
        join: ra in RemoteActor,
        on: ra.id == fi.remote_actor_id,
        where: uf.user_id == ^user.id and uf.state == @state_accepted,
        where: is_nil(fi.deleted_at),
        # Non-public content stays off this surface too, and the rule turns on
        # the activity type because that is what decides whose audience the
        # viewer is in.
        #
        # For a `Create` the follow-join matched `remote_actor_id`, the author
        # — so the viewer *is* a follower and `followers_only` is theirs to
        # read. For an `Announce` the join matched `boosted_by_actor_id`, the
        # booster, and proves nothing about the author: a hostile instance
        # that Announces a victim's `followers_only` post to a booster local
        # people follow otherwise put that post — title, body, attachments —
        # into the feed of everyone who was never in its audience. `direct` is
        # refused either way: a DM is the Messaging context's channel, never a
        # timeline row.
        where:
          fi.visibility in ["public", "unlisted"] or
            (fi.activity_type == "Create" and fi.visibility == "followers_only"),
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
        # `ra` is joined on `remote_actor_id`, the *author*. For an Announce
        # that is the boosted account, not the booster — so muting someone you
        # follow hid their own posts and left their boosts in place, which is
        # the one thing a mute is for. (A block severs the follow, so the join
        # drops those rows anyway; a mute deliberately severs nothing.)
        hidden_by_ap_id =
          from(hra in RemoteActor, where: hra.ap_id in ^hidden_ap_ids, select: hra.id)

        from([fi, _uf, ra] in remote_query,
          where: ra.ap_id not in ^hidden_ap_ids,
          where:
            is_nil(fi.boosted_by_actor_id) or
              fi.boosted_by_actor_id not in subquery(hidden_by_ap_id)
        )
      else
        remote_query
      end

    # A muted server, as author or as booster.
    remote_query =
      if muted_domains != [] do
        muted_actor_ids =
          from(mra in RemoteActor, where: mra.domain in ^muted_domains, select: mra.id)

        from([fi, _uf, ra] in remote_query,
          where: ra.domain not in ^muted_domains,
          where:
            is_nil(fi.boosted_by_actor_id) or
              fi.boosted_by_actor_id not in subquery(muted_actor_ids)
        )
      else
        remote_query
      end

    # A followed user's articles are only timeline-visible when the follower
    # open them on the board: board-less (remote import) articles are public;
    # otherwise one of the article's boards must be at or below the
    # follower's role. Without this, following an admin surfaced titles,
    # could open them; digests and images from admin-only boards otherwise
    # surfaced in the follower's timeline.
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

    # Remote replies on the member's threads get what every other listing
    # gets: nothing that is not public (a `followers_only` or `direct` reply
    # from another server is not the member's to see here), nothing from a
    # blocked or suspended instance, and nothing the member blocked or muted —
    # one account, or a whole server. The strand applied none of it to remote
    # comments until 6E-3. `apply_hidden_filters/3` keeps `is_nil(c.user_id)
    # or …`: a remote comment has no local author, and `NULL not in (…)` is
    # NULL, which once dropped every federated reply as soon as the viewer
    # blocked anyone.
    comment_query =
      comment_query
      |> Filters.exclude_unservable_remote()
      |> Filters.apply_hidden_filters(
        hidden_user_ids,
        if(muted_domains == [], do: hidden_ap_ids, else: {hidden_ap_ids, muted_domains})
      )

    {remote_total, local_total, comment_total} =
      count_timeline_totals(user.id, hidden_user_ids, hidden_ap_ids, muted_domains, allowed_roles)

    total = remote_total + local_total + comment_total

    remote_items =
      from([fi, _uf, ra] in remote_query,
        order_by: [desc: fi.published_at, desc: fi.id],
        limit: ^(offset + per_page),
        preload: [:remote_actor, :boosted_by_actor]
      )
      |> Repo.all()
      |> Enum.map(fn fi ->
        %{source: :remote, timeline_item: fi, sorted_at: fi.published_at}
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
  Returns a timeline item by its ActivityPub ID, or nil.
  """
  def get_timeline_item_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.one(from(fi in TimelineItem, where: fi.ap_id == ^ap_id))
  end

  @doc """
  Soft-deletes a timeline item by AP ID, scoped to a remote actor.

  Returns `{count, nil}`.
  """
  def soft_delete_timeline_item_by_ap_id(ap_id, remote_actor_id) when is_binary(ap_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(fi in TimelineItem,
      where:
        fi.ap_id == ^ap_id and fi.remote_actor_id == ^remote_actor_id and is_nil(fi.deleted_at)
    )
    |> Repo.update_all(set: [deleted_at: now])
  end

  @doc """
  Bulk soft-deletes all timeline items from a given remote actor.

  Used when a remote actor is deleted. Returns `{count, nil}`.
  """
  def cleanup_timeline_items_for_actor(remote_actor_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(fi in TimelineItem,
      where: fi.remote_actor_id == ^remote_actor_id and is_nil(fi.deleted_at)
    )
    |> Repo.update_all(set: [deleted_at: now])
  end

  @doc """
  Repoints timeline items from a migrated remote actor to its new identity.

  Called after a verified inbound `Move`. Feed membership is a query-time join
  on `user_follows`, so migrating the follow without migrating the items would
  make every item the actor had already published vanish from its followers'
  feeds — and, because `timeline_item_accessible?/2` resolves the same source
  actor, become un-likeable, un-boostable, un-repliable, and un-forwardable.

  Both roles are repointed: `remote_actor_id` (the author of a `Create`, or the
  original author of an `Announce`) and `boosted_by_actor_id` (the booster,
  which is what `Announce` timeline membership keys on).

  Only timeline items move. Articles and comments keep their original
  `remote_actor_id`: they are board content with their own permalinks and
  `ap_id`s, and rewriting their authorship would retroactively reattribute
  posts that remain published under the old actor on its own instance.

  Returns `{create_count, announce_count}`.
  """
  @spec migrate_timeline_items(integer(), integer()) :: {non_neg_integer(), non_neg_integer()}
  def migrate_timeline_items(old_actor_id, new_actor_id)
      when is_integer(old_actor_id) and is_integer(new_actor_id) do
    {authored, _} =
      from(fi in TimelineItem, where: fi.remote_actor_id == ^old_actor_id)
      |> Repo.update_all(set: [remote_actor_id: new_actor_id])

    {boosted, _} =
      from(fi in TimelineItem, where: fi.boosted_by_actor_id == ^old_actor_id)
      |> Repo.update_all(set: [boosted_by_actor_id: new_actor_id])

    {authored, boosted}
  end

  @doc """
  Creates a reply to a remote timeline item and schedules federation delivery.

  Renders the body as Markdown → HTML, generates an AP ID, inserts the
  `TimelineItemReply` record, and enqueues a `Create(Note)` activity for
  delivery to the remote actor's inbox and the replying user's AP followers.

  The timeline item must be reachable from the user's timeline
  (`timeline_item_accessible?/2`) — consistent with liking and boosting. Callers
  resolve the item from a client-supplied ID, so replying to a soft-deleted
  or non-followed item is refused here at the context boundary rather than
  federating a `Create(Note)` to an unrelated remote inbox.

  Returns `{:ok, %TimelineItemReply{}}`, `{:error, :not_found}`, the sanction
  gate's refusals (ADR 0029), `{:error, :blocked}` (the user has blocked the
  item's author), `{:error, :content_filtered}` (ADR 0065), a new account's
  refusals from `Baudrate.Auth.Trust` (ADR 0064), or `{:error, changeset}`.
  """
  def create_timeline_item_reply(timeline_item, user, body, opts \\ []) do
    # A moved, silenced or suspended account cannot reply (ADR 0029).
    gate = Baudrate.Auth.ensure_can_interact(user)

    cond do
      not timeline_item_accessible?(user, timeline_item) -> {:error, :not_found}
      gate != :ok -> gate
      Baudrate.Auth.blocked_with_author?(user.id, timeline_item) -> {:error, :blocked}
      true -> screen_and_create_reply(timeline_item, user, body, opts)
    end
  end

  # A reply leaves the site as surely as an article does, so the content
  # filters (ADR 0065) and a new account's link and image limits (ADR 0064)
  # apply to it too, and it takes a place in the same hourly bucket — the
  # filter first and the bucket last, so a refused reply spends nothing.
  #
  # A reply cannot be held: it is addressed to somebody on another server, and
  # holding it would mean deciding later whether to send it. A `hold` filter
  # flags it, and since a reply has no page of its own here, the report keeps
  # a copy of its text.
  defp screen_and_create_reply(timeline_item, user, body, opts) do
    image_count = opts |> Keyword.get(:image_ids, []) |> Enum.uniq() |> length()

    verdict =
      Baudrate.Moderation.ContentFilters.screen(
        %{
          body: body,
          extra: fn ->
            Baudrate.Federation.ReplyImages.reply_image_alts(
              Keyword.get(opts, :image_ids, []),
              user.id
            )
          end
        },
        mode: :publish,
        target_type: "timeline_reply",
        user_id: user.id
      )

    with :ok <- Baudrate.Moderation.ContentFilters.refuse_blocked(verdict),
         :ok <- Baudrate.Auth.check_post(user, body, image_count) do
      Baudrate.Moderation.ContentFilters.record(verdict)

      timeline_item
      |> do_create_timeline_item_reply(user, body, opts)
      |> tap(fn
        {:ok, _reply} ->
          Baudrate.Moderation.ContentFilters.flag(verdict, %{reported_user_id: user.id},
            evidence: body
          )

        _ ->
          :ok
      end)
    end
  end

  defp do_create_timeline_item_reply(timeline_item, user, body, opts) do
    # Likes, boosts and replies written before the rename keep their
    # `#feed-*` fragments: an `ap_id` is immutable once published, and remote
    # servers hold it. Undo reads the stored value rather than rebuilding it
    # (see `toggle_timeline_item_like/2`), so the two forms coexist harmlessly.
    ap_id =
      "#{Baudrate.Federation.actor_uri(:user, user.username)}#timeline-reply-#{Ecto.UUID.generate()}"

    body_html = Markdown.to_html(body)
    image_ids = Keyword.get(opts, :image_ids, [])

    attrs = %{
      timeline_item_id: timeline_item.id,
      user_id: user.id,
      body: body,
      body_html: body_html,
      ap_id: ap_id,
      # Optional content warning from the composer (ADR 0052); normalised and
      # bounded by `Content.ContentWarning.validate/1` in the changeset.
      summary: Keyword.get(opts, :summary)
    }

    # The reply, its images and its Create(Note) jobs commit together
    # (Phase 2C); the Note carries the images, so they are attached first.
    Baudrate.Federation.federate(
      fn ->
        with {:ok, reply} <-
               %TimelineItemReply{} |> TimelineItemReply.changeset(attrs) |> Repo.insert() do
          if image_ids != [] do
            ReplyImages.associate_reply_images(reply.id, image_ids, user.id)
          end

          {:ok, reply}
        end
      end,
      &Publisher.publish_timeline_item_reply(Repo.preload(&1, :images), timeline_item)
    )
  end

  @doc """
  Lists replies for a timeline item, ordered by insertion time ascending.

  Preloads the `:user` association (with `:role`).
  """
  def list_timeline_item_replies(timeline_item_id) do
    from(r in TimelineItemReply,
      where: r.timeline_item_id == ^timeline_item_id,
      order_by: [asc: r.inserted_at, asc: r.id],
      preload: [:images, user: :role]
    )
    |> Repo.all()
  end

  @doc """
  Batch-counts replies grouped by timeline item ID.

  Accepts a list of timeline item IDs and returns a map of
  `%{timeline_item_id => count}`.
  """
  def count_timeline_item_replies(timeline_item_ids) when is_list(timeline_item_ids) do
    if timeline_item_ids == [] do
      %{}
    else
      from(r in TimelineItemReply,
        where: r.timeline_item_id in ^timeline_item_ids,
        group_by: r.timeline_item_id,
        select: {r.timeline_item_id, count(r.id)}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @doc """
  Toggles a like on a remote timeline item — creates if not exists, removes if exists.
  Sends AP Like/Undo(Like) to the remote actor's inbox.
  """
  def toggle_timeline_item_like(user, timeline_item_id) do
    case Repo.get(TimelineItem, timeline_item_id) do
      nil ->
        {:error, :not_found}

      timeline_item ->
        if not timeline_item_accessible?(user, timeline_item) do
          {:error, :not_found}
        else
          do_toggle_timeline_item_like(user, timeline_item)
        end
    end
  end

  @doc """
  Returns a MapSet of timeline item IDs that the given user has liked.
  """
  def timeline_item_likes_by_user(_user_id, []), do: MapSet.new()

  def timeline_item_likes_by_user(user_id, timeline_item_ids) do
    from(l in TimelineItemLike,
      where: l.user_id == ^user_id and l.timeline_item_id in ^timeline_item_ids,
      select: l.timeline_item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Toggles a boost on a remote timeline item — creates if not exists, removes if exists.
  Sends AP Announce/Undo(Announce) to the remote actor's inbox.
  """
  def toggle_timeline_item_boost(user, timeline_item_id) do
    case Repo.get(TimelineItem, timeline_item_id) do
      nil ->
        {:error, :not_found}

      timeline_item ->
        if not timeline_item_accessible?(user, timeline_item) do
          {:error, :not_found}
        else
          do_toggle_timeline_item_boost(user, timeline_item)
        end
    end
  end

  @doc """
  Returns a MapSet of timeline item IDs that the given user has boosted.
  """
  def timeline_item_boosts_by_user(_user_id, []), do: MapSet.new()

  def timeline_item_boosts_by_user(user_id, timeline_item_ids) do
    from(b in TimelineItemBoost,
      where: b.user_id == ^user_id and b.timeline_item_id in ^timeline_item_ids,
      select: b.timeline_item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # --- Private ---

  defp ensure_author_not_blocked(user, timeline_item) do
    if Baudrate.Auth.blocked_with_author?(user.id, timeline_item),
      do: {:error, :blocked},
      else: :ok
  end

  defp do_toggle_timeline_item_like(user, timeline_item) do
    timeline_item_id = timeline_item.id

    case Repo.get_by(TimelineItemLike, user_id: user.id, timeline_item_id: timeline_item_id) do
      nil ->
        # A restricted account and a blocked author are the same shape here:
        # both can undo an earlier like, not add a new one (ADR 0029).
        with :ok <- Baudrate.Auth.ensure_can_interact(user),
             :ok <- ensure_author_not_blocked(user, timeline_item) do
          Baudrate.Federation.federate(
            fn ->
              with {:ok, like} <-
                     %TimelineItemLike{}
                     |> TimelineItemLike.changeset(%{
                       user_id: user.id,
                       timeline_item_id: timeline_item_id
                     })
                     |> Repo.insert() do
                ap_id =
                  Baudrate.Federation.actor_uri(:user, user.username) <>
                    "#timeline-like-#{like.id}"

                {:ok, like |> Ecto.Changeset.change(ap_id: ap_id) |> Repo.update!()}
              end
            end,
            fn _like -> Publisher.publish_timeline_item_liked(user, timeline_item) end
          )
        end

      like ->
        like_ap_id = like.ap_id

        {:ok, _} =
          Repo.transaction(fn ->
            Repo.delete!(like)
            Publisher.publish_timeline_item_unliked(user, timeline_item, like_ap_id)
          end)

        {:ok, :removed}
    end
  end

  defp do_toggle_timeline_item_boost(user, timeline_item) do
    timeline_item_id = timeline_item.id

    case Repo.get_by(TimelineItemBoost, user_id: user.id, timeline_item_id: timeline_item_id) do
      nil ->
        # A restricted account and a blocked author are the same shape here:
        # both can undo an earlier boost, not add a new one (ADR 0029).
        with :ok <- Baudrate.Auth.ensure_can_interact(user),
             :ok <- ensure_author_not_blocked(user, timeline_item) do
          Baudrate.Federation.federate(
            fn ->
              with {:ok, boost} <-
                     %TimelineItemBoost{}
                     |> TimelineItemBoost.changeset(%{
                       user_id: user.id,
                       timeline_item_id: timeline_item_id
                     })
                     |> Repo.insert() do
                ap_id =
                  Baudrate.Federation.actor_uri(:user, user.username) <>
                    "#timeline-announce-#{boost.id}"

                {:ok, boost |> Ecto.Changeset.change(ap_id: ap_id) |> Repo.update!()}
              end
            end,
            fn _boost -> Publisher.publish_timeline_item_boosted(user, timeline_item) end
          )
        end

      boost ->
        boost_ap_id = boost.ap_id

        {:ok, _} =
          Repo.transaction(fn ->
            Repo.delete!(boost)
            Publisher.publish_timeline_item_unboosted(user, timeline_item, boost_ap_id)
          end)

        {:ok, :removed}
    end
  end

  @doc """
  Returns true if `timeline_item` is reachable from `user`'s timeline.

  Mirrors the membership conditions of `list_timeline_items/2` exactly: the item
  must not be soft-deleted, and the user must have an `accepted` follow on
  the item's **source** actor — the author for `Create` activities, or the
  booster for `Announce` activities (for a boost, `remote_actor_id` is the
  original author, whom the user need not follow).

  `timeline_items` rows are global — timeline membership is a query-time join on
  `user_follows` — so every entry point that resolves a timeline item from a
  client-supplied ID (like, boost, reply, forward-to-board) must call this
  before acting on it.
  """
  @spec timeline_item_accessible?(map(), %TimelineItem{}) :: boolean()
  def timeline_item_accessible?(_user, %TimelineItem{deleted_at: deleted_at})
      when not is_nil(deleted_at),
      do: false

  def timeline_item_accessible?(user, %TimelineItem{} = timeline_item) do
    source_actor_id =
      case timeline_item.activity_type do
        "Announce" -> timeline_item.boosted_by_actor_id
        _ -> timeline_item.remote_actor_id
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

  # Counts remote timeline items, local articles, and comments in a single SQL
  # round-trip using 3 scalar subqueries. The conditions exactly mirror the
  # Ecto queries in `list_timeline_items/2`.
  defp count_timeline_totals(
         user_id,
         hidden_user_ids,
         hidden_ap_ids,
         muted_domains,
         allowed_roles
       ) do
    hidden_ap_ids_param = if hidden_ap_ids == [], do: nil, else: hidden_ap_ids
    muted_domains_param = if muted_domains == [], do: nil, else: muted_domains
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
          (SELECT count(*) FROM timeline_items fi
             JOIN user_follows uf ON (
               (fi.activity_type = 'Create' AND uf.remote_actor_id = fi.remote_actor_id) OR
               (fi.activity_type = 'Announce' AND uf.remote_actor_id = fi.boosted_by_actor_id)
             )
             JOIN remote_actors ra ON ra.id = fi.remote_actor_id
             WHERE uf.user_id = $1 AND uf.state = 'accepted'
               AND fi.deleted_at IS NULL
               AND (fi.visibility IN ('public', 'unlisted')
                    OR (fi.activity_type = 'Create' AND fi.visibility = 'followers_only'))
               AND ($2::text[] IS NULL OR ra.ap_id != ALL($2))
               AND ($2::text[] IS NULL OR NOT EXISTS (
                 SELECT 1 FROM remote_actors bra
                 WHERE bra.id = fi.boosted_by_actor_id AND bra.ap_id = ANY($2)))
               AND ($7::text[] IS NULL OR (ra.domain <> ALL($7) AND NOT EXISTS (
                 SELECT 1 FROM remote_actors mra
                 WHERE mra.id = fi.boosted_by_actor_id AND mra.domain = ANY($7))))
               AND NOT EXISTS (
                 SELECT 1 FROM remote_actors hra
                 WHERE hra.id IN (fi.remote_actor_id, fi.boosted_by_actor_id)
                   AND (hra.suspended_at IS NOT NULL
                        OR (CASE WHEN $5::boolean
                                 THEN hra.domain = ANY($6::text[])
                                 ELSE hra.domain <> ALL($6::text[]) END)))),
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
               AND ($3::bigint[] IS NULL OR c.user_id IS NULL OR c.user_id != ALL($3))
               AND (c.remote_actor_id IS NULL OR (
                 c.visibility IN ('public', 'unlisted')
                 AND NOT EXISTS (
                   SELECT 1 FROM remote_actors cra
                   WHERE cra.id = c.remote_actor_id
                     AND (($2::text[] IS NOT NULL AND cra.ap_id = ANY($2))
                          OR ($7::text[] IS NOT NULL AND cra.domain = ANY($7))
                          OR cra.suspended_at IS NOT NULL
                          OR (CASE WHEN $5::boolean
                                   THEN cra.domain = ANY($6::text[])
                                   ELSE cra.domain <> ALL($6::text[]) END))))))
        """,
        [
          user_id,
          hidden_ap_ids_param,
          hidden_user_ids_param,
          allowed_roles,
          blocklist_mode,
          domains_param,
          muted_domains_param
        ]
      )

    {remote_total, local_total, comment_total}
  end
end
