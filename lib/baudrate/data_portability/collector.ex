defmodule Baudrate.DataPortability.Collector do
  @moduledoc """
  Collects what goes into a data export, as plain maps built from explicit
  field allow-lists (ADR 0023 §9–§14).

  ## Rules every function here follows

    * **Allow-lists only.** Each record is turned into a map by naming its
      fields. Never `Map.from_struct/1`, never encode a schema. A new column,
      secret or not, stays out of the archive until someone adds it here on
      purpose.
    * **Only what the user wrote or owns, and only what they can still see.**
      Board visibility uses the same predicate as the viewer-gated profile
      listings (board-less, or at least one board at or below the user's
      role). Content in boards the user can no longer view is left out.
    * **Other people's content appears only as a URI.** A comment's parent,
      the target of a like or a bookmark, and so on.
    * **Deleted content.** Own articles are included only when live or deleted
      by the user themselves (`deleted_by_id == user.id`). Content removed by
      a moderator, and deletions without attribution, are excluded (fail
      closed). Deleted comments and DMs have their bodies overwritten
      anyway, so they are skipped.
    * **Excluded entirely:** secrets, session IPs and user agents,
      notifications, reports, the moderation log, login attempts, reading
      history, push subscriptions, revisions written by others, and messages
      sent by the other party.

  `base_url` is passed in rather than read from the endpoint, so the SysOp
  release task can build archives without a running web server.
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Auth.{InviteCode, UserBlock, UserMute, WebAuthnCredential}

  alias Baudrate.Content.{
    Article,
    ArticleBoost,
    ArticleImage,
    ArticleLike,
    ArticleRevision,
    Board,
    BoardArticle,
    Bookmark,
    Comment,
    CommentBoost,
    CommentImage,
    CommentLike,
    Filters,
    Poll,
    PollOption,
    PollVote
  }

  alias Baudrate.Federation.{
    FeedItem,
    FeedItemBoost,
    FeedItemLike,
    FeedItemReply,
    FeedItemReplyImage,
    Follower,
    RemoteActor,
    UserFollow
  }

  alias Baudrate.DataPortability.Files
  alias Baudrate.Messaging.{Conversation, DirectMessage}
  alias Baudrate.Setup.User

  @avatar_sizes [120, 48, 36, 24]

  @doc """
  Returns `{documents, media}` for `user` (with `:role` preloaded):

    * `documents` — `%{"profile.json" => map, ...}`
    * `media` — `[{entry_name, absolute_path}]` for files that passed
      `Baudrate.DataPortability.Files` confinement; `entry_name` is built from
      record ids only
  """
  @spec collect(User.t(), String.t()) :: {%{String.t() => term()}, [{String.t(), String.t()}]}
  def collect(%User{role: %{name: _}} = user, base_url) when is_binary(base_url) do
    articles = own_articles(user)
    article_ids = Enum.map(articles, & &1.id)
    comments = own_comments(user)
    replies = own_feed_replies(user)

    documents = %{
      "profile.json" => profile(user),
      "articles.json" => Enum.map(articles, &article(&1, user, base_url)),
      "comments.json" => Enum.map(comments, &comment(&1, base_url)),
      "feed_replies.json" => Enum.map(replies, &feed_reply/1),
      "interactions.json" => interactions(user, base_url),
      "relationships.json" => relationships(user, base_url),
      "messages.json" => messages(user, base_url),
      "invites.json" => invites(user)
    }

    media =
      avatar_media(user) ++
        image_media(ArticleImage, :article_id, article_ids, user, "article_images") ++
        image_media(
          CommentImage,
          :comment_id,
          Enum.map(comments, & &1.id),
          user,
          "comment_images"
        ) ++
        image_media(
          FeedItemReplyImage,
          :reply_id,
          Enum.map(replies, & &1.id),
          user,
          "feed_reply_images"
        )

    {documents, media}
  end

  # ---------------------------------------------------------------------------
  # Visibility
  # ---------------------------------------------------------------------------

  # Articles (named binding :article) the user can currently open: board-less,
  # or in at least one board at or below the user's role. Same predicate as
  # the viewer-gated `Content.*_by_user` listings.
  defp where_viewable(query, user) do
    roles = Filters.allowed_view_roles(user)

    from([article: a] in query,
      where:
        not exists(
          from(ba in BoardArticle, where: ba.article_id == parent_as(:article).id, select: 1)
        ) or
          exists(
            from(ba in BoardArticle,
              join: b in Board,
              on: b.id == ba.board_id,
              where: ba.article_id == parent_as(:article).id and b.min_role_to_view in ^roles,
              select: 1
            )
          )
    )
  end

  # Remote articles that are not public/unlisted stay off every surface.
  defp where_publicly_servable(query) do
    from([article: a] in query,
      where: is_nil(a.remote_actor_id) or a.visibility in ["public", "unlisted"]
    )
  end

  defp visible_live_articles(user) do
    from(a in Article, as: :article, where: is_nil(a.deleted_at))
    |> where_viewable(user)
    |> where_publicly_servable()
  end

  # ---------------------------------------------------------------------------
  # Profile
  # ---------------------------------------------------------------------------

  defp profile(user) do
    keys =
      Repo.all(
        from(c in WebAuthnCredential,
          where: c.user_id == ^user.id,
          order_by: [asc: c.inserted_at, asc: c.id]
        )
      )

    %{
      "username" => user.username,
      "display_name" => user.display_name,
      "bio" => user.bio,
      "signature" => user.signature,
      "profile_fields" =>
        Enum.map(user.profile_fields || [], fn f ->
          %{"name" => f["name"], "value" => f["value"]}
        end),
      "preferred_locales" => user.preferred_locales || [],
      "dm_access" => user.dm_access,
      "notification_preferences" => user.notification_preferences || %{},
      "role" => user.role.name,
      "created_at" => iso(user.inserted_at),
      "two_factor" => %{"totp_enabled" => user.totp_enabled == true},
      "also_known_as" => user.also_known_as || [],
      "moved_to" => user.moved_to,
      "security_keys" =>
        Enum.map(keys, fn k ->
          %{
            "label" => k.label,
            "added_at" => iso(k.inserted_at),
            "last_used_at" => iso(k.last_used_at)
          }
        end)
    }
  end

  # ---------------------------------------------------------------------------
  # Articles, comments, replies
  # ---------------------------------------------------------------------------

  defp own_articles(user) do
    from(a in Article,
      as: :article,
      where:
        a.user_id == ^user.id and
          (is_nil(a.deleted_at) or a.deleted_by_id == ^user.id),
      order_by: [asc: a.inserted_at, asc: a.id]
    )
    |> where_viewable(user)
    |> Repo.all()
    |> Repo.preload(boards: from(b in Board, order_by: b.id))
  end

  defp article(a, user, base_url) do
    roles = Filters.allowed_view_roles(user)

    revisions =
      Repo.all(
        from(r in ArticleRevision,
          where: r.article_id == ^a.id and r.editor_id == ^user.id,
          order_by: [asc: r.inserted_at, asc: r.id]
        )
      )

    poll = Repo.one(from(p in Poll, where: p.article_id == ^a.id))

    options =
      if poll,
        do: Repo.all(from(o in PollOption, where: o.poll_id == ^poll.id, order_by: o.position)),
        else: []

    image_ids =
      Repo.all(
        from(i in ArticleImage,
          where: i.article_id == ^a.id and i.user_id == ^user.id,
          order_by: i.id,
          select: i.id
        )
      )

    %{
      "id" => a.id,
      "uri" => article_uri(a, base_url),
      "url" => "#{base_url}/articles/#{a.slug}",
      "slug" => a.slug,
      "title" => a.title,
      "body" => a.body,
      "visibility" => a.visibility,
      "forwardable" => a.forwardable,
      "created_at" => iso(a.inserted_at),
      "updated_at" => iso(a.updated_at),
      "deleted_at" => iso(a.deleted_at),
      # Only boards the user can still open; a cross-post into a board they
      # lost access to does not reveal that board's name.
      "boards" => for(b <- a.boards, b.min_role_to_view in roles, do: b.slug),
      "revisions" =>
        Enum.map(revisions, fn r ->
          %{"title" => r.title, "body" => r.body, "created_at" => iso(r.inserted_at)}
        end),
      "poll" =>
        poll &&
          %{
            "mode" => poll.mode,
            "closes_at" => iso(poll.closes_at),
            "options" => Enum.map(options, & &1.text)
          },
      "images" => Enum.map(image_ids, &"media/article_images/#{&1}.webp")
    }
  end

  defp own_comments(user) do
    from(c in Comment,
      join: a in assoc(c, :article),
      as: :article,
      where: c.user_id == ^user.id and is_nil(c.deleted_at) and is_nil(a.deleted_at),
      order_by: [asc: c.inserted_at, asc: c.id],
      preload: [article: a]
    )
    |> where_viewable(user)
    |> where_publicly_servable()
    |> Repo.all()
    |> Repo.preload(:parent)
  end

  defp comment(c, base_url) do
    image_ids =
      Repo.all(
        from(i in CommentImage,
          where: i.comment_id == ^c.id and i.user_id == ^c.user_id,
          order_by: i.id,
          select: i.id
        )
      )

    %{
      "id" => c.id,
      "uri" => c.ap_id,
      "body" => c.body,
      "visibility" => c.visibility,
      "created_at" => iso(c.inserted_at),
      "updated_at" => iso(c.updated_at),
      "article_uri" => article_uri(c.article, base_url),
      "in_reply_to" =>
        case c.parent do
          %Comment{ap_id: ap_id} -> ap_id
          _ -> article_uri(c.article, base_url)
        end,
      "images" => Enum.map(image_ids, &"media/comment_images/#{&1}.webp")
    }
  end

  defp own_feed_replies(user) do
    Repo.all(
      from(r in FeedItemReply,
        join: f in assoc(r, :feed_item),
        where: r.user_id == ^user.id and is_nil(f.deleted_at),
        order_by: [asc: r.inserted_at, asc: r.id],
        preload: [feed_item: f]
      )
    )
  end

  defp feed_reply(r) do
    image_ids =
      Repo.all(
        from(i in FeedItemReplyImage,
          where: i.reply_id == ^r.id and i.user_id == ^r.user_id,
          order_by: i.id,
          select: i.id
        )
      )

    %{
      "id" => r.id,
      "uri" => r.ap_id,
      "body" => r.body,
      "created_at" => iso(r.inserted_at),
      "in_reply_to" => r.feed_item.ap_id,
      "images" => Enum.map(image_ids, &"media/feed_reply_images/#{&1}.webp")
    }
  end

  # ---------------------------------------------------------------------------
  # Interactions: target URIs only
  # ---------------------------------------------------------------------------

  defp interactions(user, base_url) do
    visible = visible_live_articles(user)

    %{
      "article_likes" => article_targets(ArticleLike, user, visible, base_url),
      "article_boosts" => article_targets(ArticleBoost, user, visible, base_url),
      "comment_likes" => comment_targets(CommentLike, user, visible),
      "comment_boosts" => comment_targets(CommentBoost, user, visible),
      "feed_item_likes" => feed_item_targets(FeedItemLike, user),
      "feed_item_boosts" => feed_item_targets(FeedItemBoost, user),
      "poll_votes" => poll_votes(user, visible, base_url),
      "bookmarks" => bookmarks(user, visible, base_url)
    }
  end

  defp article_targets(schema, user, visible, base_url) do
    Repo.all(
      from(x in schema,
        join: a in subquery(visible),
        on: a.id == x.article_id,
        where: x.user_id == ^user.id,
        order_by: [asc: x.inserted_at, asc: x.id],
        select: {x.inserted_at, a.ap_id, a.slug}
      )
    )
    |> Enum.map(fn {at, ap_id, slug} ->
      %{"target" => ap_id || "#{base_url}/ap/articles/#{slug}", "created_at" => iso(at)}
    end)
  end

  defp comment_targets(schema, user, visible) do
    Repo.all(
      from(x in schema,
        join: c in Comment,
        on: c.id == x.comment_id,
        join: a in subquery(visible),
        on: a.id == c.article_id,
        where: x.user_id == ^user.id and is_nil(c.deleted_at),
        order_by: [asc: x.inserted_at, asc: x.id],
        select: {x.inserted_at, c.ap_id}
      )
    )
    |> Enum.map(fn {at, uri} -> %{"target" => uri, "created_at" => iso(at)} end)
  end

  defp feed_item_targets(schema, user) do
    Repo.all(
      from(x in schema,
        join: f in FeedItem,
        on: f.id == x.feed_item_id,
        where: x.user_id == ^user.id and is_nil(f.deleted_at),
        order_by: [asc: x.inserted_at, asc: x.id],
        select: {x.inserted_at, f.ap_id}
      )
    )
    |> Enum.map(fn {at, uri} -> %{"target" => uri, "created_at" => iso(at)} end)
  end

  defp poll_votes(user, visible, base_url) do
    Repo.all(
      from(v in PollVote,
        join: o in PollOption,
        on: o.id == v.poll_option_id,
        join: p in Poll,
        on: p.id == v.poll_id,
        join: a in subquery(visible),
        on: a.id == p.article_id,
        where: v.user_id == ^user.id,
        order_by: [asc: v.inserted_at, asc: v.id],
        select: {v.inserted_at, p.ap_id, a.ap_id, a.slug, o.text}
      )
    )
    |> Enum.map(fn {at, poll_uri, article_ap_id, slug, text} ->
      %{
        "poll" => poll_uri || article_ap_id || "#{base_url}/ap/articles/#{slug}",
        "option" => text,
        "created_at" => iso(at)
      }
    end)
  end

  defp bookmarks(user, visible, base_url) do
    articles =
      Repo.all(
        from(b in Bookmark,
          join: a in subquery(visible),
          on: a.id == b.article_id,
          where: b.user_id == ^user.id,
          select: {b.inserted_at, b.id, a.ap_id, a.slug}
        )
      )
      |> Enum.map(fn {at, id, ap_id, slug} ->
        {at, id, ap_id || "#{base_url}/ap/articles/#{slug}"}
      end)

    comments =
      Repo.all(
        from(b in Bookmark,
          join: c in Comment,
          on: c.id == b.comment_id,
          join: a in subquery(visible),
          on: a.id == c.article_id,
          where: b.user_id == ^user.id and is_nil(c.deleted_at),
          select: {b.inserted_at, b.id, c.ap_id}
        )
      )

    (articles ++ comments)
    |> Enum.sort_by(fn {at, id, _} -> {DateTime.to_unix(to_datetime(at)), id} end)
    |> Enum.map(fn {at, _id, uri} -> %{"target" => uri, "created_at" => iso(at)} end)
  end

  # ---------------------------------------------------------------------------
  # Relationships
  # ---------------------------------------------------------------------------

  defp relationships(user, base_url) do
    following =
      Repo.all(
        from(f in UserFollow,
          where: f.user_id == ^user.id,
          order_by: [asc: f.inserted_at, asc: f.id],
          preload: [:remote_actor, :followed_user]
        )
      )
      |> Enum.map(fn f ->
        Map.merge(account_ref(f.followed_user, f.remote_actor, base_url), %{
          "state" => f.state,
          "created_at" => iso(f.inserted_at)
        })
      end)

    local_followers =
      Repo.all(
        from(f in UserFollow,
          join: u in User,
          on: u.id == f.user_id,
          where: f.followed_user_id == ^user.id and f.state == "accepted",
          order_by: [asc: f.inserted_at, asc: f.id],
          select: u
        )
      )
      |> Enum.map(&account_ref(&1, nil, base_url))

    remote_followers =
      Repo.all(
        from(f in Follower,
          where: f.actor_uri == ^actor_uri(user.username, base_url),
          order_by: [asc: f.inserted_at, asc: f.id],
          preload: [:remote_actor]
        )
      )
      |> Enum.map(fn f ->
        case f.remote_actor do
          %RemoteActor{} = actor -> account_ref(nil, actor, base_url)
          nil -> %{"uri" => f.follower_uri}
        end
      end)

    blocks =
      Repo.all(
        from(b in UserBlock,
          where: b.user_id == ^user.id,
          order_by: [asc: b.inserted_at, asc: b.id],
          preload: [:blocked_user]
        )
      )
      |> Enum.map(&block_ref(&1.blocked_user, &1.blocked_actor_ap_id, base_url))

    mutes =
      Repo.all(
        from(m in UserMute,
          where: m.user_id == ^user.id,
          order_by: [asc: m.inserted_at, asc: m.id],
          preload: [:muted_user]
        )
      )
      |> Enum.map(&block_ref(&1.muted_user, &1.muted_actor_ap_id, base_url))

    %{
      "following" => following,
      "followers" => local_followers ++ remote_followers,
      "blocks" => blocks,
      "mutes" => mutes
    }
  end

  defp account_ref(%User{username: username}, _remote, base_url),
    do: %{"handle" => username, "uri" => actor_uri(username, base_url)}

  defp account_ref(_local, %RemoteActor{} = actor, _base_url),
    do: %{"handle" => "#{actor.username}@#{actor.domain}", "uri" => actor.ap_id}

  defp account_ref(_local, _remote, _base_url), do: %{}

  defp block_ref(%User{} = user, _ap_id, base_url), do: account_ref(user, nil, base_url)
  defp block_ref(_user, ap_id, _base_url) when is_binary(ap_id), do: %{"uri" => ap_id}
  defp block_ref(_user, _ap_id, _base_url), do: %{}

  # ---------------------------------------------------------------------------
  # Messages: the user's own messages, counterpart by handle only
  # ---------------------------------------------------------------------------

  defp messages(user, base_url) do
    conversations =
      Repo.all(
        from(c in Conversation,
          where: c.user_a_id == ^user.id or c.user_b_id == ^user.id,
          order_by: [asc: c.inserted_at, asc: c.id],
          preload: [:user_a, :user_b, :remote_actor_a, :remote_actor_b]
        )
      )

    Enum.map(conversations, fn conv ->
      sent =
        Repo.all(
          from(m in DirectMessage,
            where:
              m.conversation_id == ^conv.id and m.sender_user_id == ^user.id and
                is_nil(m.deleted_at),
            order_by: [asc: m.inserted_at, asc: m.id]
          )
        )

      %{
        "with" => counterpart(conv, user, base_url),
        "messages_sent" =>
          Enum.map(sent, fn m ->
            %{"uri" => m.ap_id, "body" => m.body, "created_at" => iso(m.inserted_at)}
          end)
      }
    end)
  end

  defp counterpart(conv, user, base_url) do
    cond do
      conv.user_a_id == user.id and conv.user_b -> account_ref(conv.user_b, nil, base_url)
      conv.user_b_id == user.id and conv.user_a -> account_ref(conv.user_a, nil, base_url)
      conv.remote_actor_b -> account_ref(nil, conv.remote_actor_b, base_url)
      conv.remote_actor_a -> account_ref(nil, conv.remote_actor_a, base_url)
      true -> %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Invites: never an active code, never who used it
  # ---------------------------------------------------------------------------

  defp invites(user) do
    now = DateTime.utc_now()

    Repo.all(
      from(i in InviteCode,
        where: i.created_by_id == ^user.id,
        order_by: [asc: i.inserted_at, asc: i.id]
      )
    )
    |> Enum.map(fn i ->
      status = invite_status(i, now)

      %{
        # An active code is a bearer secret: never exported.
        "code" => if(status == "active", do: nil, else: i.code),
        "status" => status,
        "max_uses" => i.max_uses,
        "use_count" => i.use_count,
        "created_at" => iso(i.inserted_at),
        "expires_at" => iso(i.expires_at)
      }
    end)
  end

  defp invite_status(%InviteCode{revoked: true}, _now), do: "revoked"

  defp invite_status(%InviteCode{} = i, now) do
    cond do
      i.use_count >= i.max_uses -> "used"
      i.expires_at && DateTime.compare(i.expires_at, now) != :gt -> "expired"
      true -> "active"
    end
  end

  # ---------------------------------------------------------------------------
  # Media
  # ---------------------------------------------------------------------------

  defp avatar_media(%User{avatar_id: avatar_id}) when is_binary(avatar_id) do
    for size <- @avatar_sizes, {:ok, path} <- [Files.avatar_path(avatar_id, size)] do
      {"media/avatar/#{size}.webp", path}
    end
  end

  defp avatar_media(_user), do: []

  # Images owned by the user and attached to records already in the export.
  # `storage_path` is ignored: the path is rebuilt from `filename` (see Files).
  defp image_media(_schema, _fk, [], _user, _dir), do: []

  defp image_media(schema, fk, parent_ids, user, dir) do
    Repo.all(
      from(i in schema,
        where: field(i, ^fk) in ^parent_ids and i.user_id == ^user.id,
        order_by: i.id,
        select: {i.id, i.filename}
      )
    )
    |> Enum.flat_map(fn {id, filename} ->
      case Files.image_path("article_images", filename) do
        {:ok, path} -> [{"media/#{dir}/#{id}.webp", path}]
        :error -> []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp article_uri(%Article{ap_id: ap_id}, _base_url) when is_binary(ap_id), do: ap_id
  defp article_uri(%Article{slug: slug}, base_url), do: "#{base_url}/ap/articles/#{slug}"

  defp actor_uri(username, base_url), do: "#{base_url}/ap/users/#{username}"

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt) <> "Z"

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
end
