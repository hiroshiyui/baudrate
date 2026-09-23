defmodule Baudrate.Notification.Hooks do
  @moduledoc """
  Fire-and-forget notification creation hooks.

  Each function loads the necessary data, extracts mentions where applicable,
  and calls `Notification.create_notification/1`. Self-notification, block/mute
  suppression, and deduplication are handled by the notification context — hooks
  simply call it and ignore the result.

  ## Hook functions

    * `notify_comment_created/1` — reply_to_article, reply_to_comment, mention
    * `notify_article_created/1` — mention
    * `notify_remote_article_liked/2` — article_liked (remote actor)
    * `notify_local_article_liked/2` — article_liked (local user)
    * `notify_local_comment_liked/2` — comment_liked (local user)
    * `notify_local_article_boosted/2` — article_boosted (local user)
    * `notify_remote_article_boosted/2` — article_boosted (remote actor)
    * `notify_local_comment_boosted/2` — comment_boosted (local user)
    * `notify_remote_comment_boosted/2` — comment_boosted (remote actor)
    * `notify_remote_comment_liked/2` — comment_liked (remote actor)
    * `notify_article_forwarded/2` — article_forwarded
    * `notify_local_follow/2` — new_follower
    * `notify_remote_follow/2` — new_follower (remote actor)
    * `notify_remote_comment_created/4` — reply_to_article, reply_to_comment
    * `notify_report_created/1` — moderation_report (all admins)
    * `notify_post_held/1` — held_post (whoever can review it, ADR 0065)
    * `notify_post_approved/2` / `notify_post_rejected/1` — post_approved,
      post_rejected (the author)
    * `notify_account_security/3` — security_key_added, security_key_removed,
      totp_enabled, totp_disabled, password_changed, signed_out_everywhere,
      totp_login_failed, account_alias_added, account_alias_removed,
      account_move_requested, account_move_cancelled, account_move_failed,
      account_moved, account_redirect_removed, account_deletion_requested,
      account_deletion_cancelled, data_export_*
    * `notify_actor_moved/3` — actor_moved
    * `notify_board_actor_moved/2` — board_actor_moved (all admins)
    * `notify_health_alert/1` / `notify_health_recovered/0` — health_alert,
      health_recovered (all admins, ADR 0044)
  """

  alias Baudrate.{Auth, Notification, Repo, Setup}
  alias BaudrateWeb.ArticleHelpers
  import Ecto.Query, only: [from: 2]

  alias Baudrate.Content.{Article, BoardArticle, BoardModerator, Comment}
  alias Baudrate.Moderation.Report

  @doc """
  Notifies the article author of a reply, the parent comment author of a
  threaded reply, and any @mentioned users when a local comment is created.
  """
  def notify_comment_created(%Comment{} = comment) do
    article = Repo.get(Article, comment.article_id)

    # Notify article author of reply
    if article && article.user_id do
      Notification.create_notification(%{
        type: "reply_to_article",
        user_id: article.user_id,
        actor_user_id: comment.user_id,
        article_id: article.id,
        comment_id: comment.id
      })
    end

    # Notify parent comment author of threaded reply
    if comment.parent_id do
      parent = Repo.get(Comment, comment.parent_id)

      if parent && parent.user_id do
        Notification.create_notification(%{
          type: "reply_to_comment",
          user_id: parent.user_id,
          actor_user_id: comment.user_id,
          article_id: comment.article_id,
          comment_id: comment.id
        })
      end
    end

    # Notify @mentioned users
    notify_mentions(comment.body, comment.user_id, comment.article_id, comment.id)
  end

  @doc """
  Notifies @mentioned users when a local article is created.
  """
  def notify_article_created(%Article{} = article) do
    notify_mentions(article.body, article.user_id, article.id, nil)
  end

  @doc """
  Notifies the article author when their article receives a remote like.
  """
  def notify_remote_article_liked(article_id, remote_actor_id) do
    article = Repo.get(Article, article_id)

    if article && article.user_id do
      Notification.create_notification(%{
        type: "article_liked",
        user_id: article.user_id,
        actor_remote_actor_id: remote_actor_id,
        article_id: article.id
      })
    end
  end

  @doc """
  Notifies the article author when their article receives a local like.
  """
  def notify_local_article_liked(article_id, liker_user_id) do
    article = Repo.get(Article, article_id)

    if article && article.user_id do
      Notification.create_notification(%{
        type: "article_liked",
        user_id: article.user_id,
        actor_user_id: liker_user_id,
        article_id: article.id
      })
    end
  end

  @doc """
  Notifies the comment author when their comment receives a local like.
  """
  def notify_local_comment_liked(comment_id, liker_user_id) do
    comment = Repo.get(Comment, comment_id)

    if comment && comment.user_id do
      Notification.create_notification(%{
        type: "comment_liked",
        user_id: comment.user_id,
        actor_user_id: liker_user_id,
        article_id: comment.article_id,
        comment_id: comment.id
      })
    end
  end

  @doc """
  Notifies the article author when their article is forwarded to a board.
  """
  def notify_article_forwarded(%Article{} = article, forwarder_user_id) do
    if article.user_id do
      Notification.create_notification(%{
        type: "article_forwarded",
        user_id: article.user_id,
        actor_user_id: forwarder_user_id,
        article_id: article.id
      })
    end
  end

  @doc """
  Notifies a user that one of their second factors changed.

  `type` must be one of `Notification.Notification.security_types/0`. These
  notices have no actor and are delivered regardless of notification
  preferences, so that a user notices a change they did not make (ADR 0022).
  `data` carries display-only context such as a security key's `"label"`.
  """
  def notify_account_security(user_id, type, data \\ %{})
      when is_integer(user_id) and is_binary(type) and is_map(data) do
    if type in Baudrate.Notification.Notification.always_delivered_types() do
      Notification.create_notification(%{type: type, user_id: user_id, data: data})
    else
      {:error, :not_a_security_type}
    end
  end

  @doc """
  Tells a member who approves followers manually that another local member
  asked to follow them (ADR 0073).
  """
  def notify_follow_request(follower_id, followed_id) do
    Notification.create_notification(%{
      type: "follow_request",
      user_id: followed_id,
      actor_user_id: follower_id
    })
  end

  @doc """
  Tells a member who approves followers manually that an account on another
  server asked to follow them (ADR 0073).
  """
  def notify_remote_follow_request(user_id, remote_actor_id) do
    Notification.create_notification(%{
      type: "follow_request",
      user_id: user_id,
      actor_remote_actor_id: remote_actor_id
    })
  end

  @doc """
  Notifies a local member that another local member followed them.
  """
  def notify_local_follow(follower_id, followed_id) do
    Notification.create_notification(%{
      type: "new_follower",
      user_id: followed_id,
      actor_user_id: follower_id
    })
  end

  @doc """
  Notifies a local user that an account they followed moved and that they now
  follow the new account (ADR 0025).

  `actor` is `%{actor_user_id: id}` for a local account or
  `%{actor_remote_actor_id: id}` for a remote one. `data` carries `"label"`
  (the new account's handle) and `"url"`.
  """
  def notify_actor_moved(user_id, actor, data) when is_map(actor) and is_map(data) do
    actor
    |> Map.take([:actor_user_id, :actor_remote_actor_id])
    |> Map.merge(%{type: "actor_moved", user_id: user_id, data: data})
    |> Notification.create_notification()
  end

  @doc """
  Tells every admin that a remote account followed by one or more boards has
  moved. Board follows are never switched over automatically, since they
  decide what appears in a board (ADR 0025). `data` carries `"label"` (the new
  account) and `"boards"` (board names).
  """
  def notify_board_actor_moved(remote_actor_id, data) when is_map(data) do
    Enum.each(Setup.admin_user_ids(), fn admin_id ->
      Notification.create_notification(%{
        type: "board_actor_moved",
        user_id: admin_id,
        actor_remote_actor_id: remote_actor_id,
        data: data
      })
    end)
  end

  @doc """
  Notifies a local user when a remote actor follows them.
  """
  def notify_remote_follow(user_id, remote_actor_id) do
    Notification.create_notification(%{
      type: "new_follower",
      user_id: user_id,
      actor_remote_actor_id: remote_actor_id
    })
  end

  @doc """
  Notifies the article author and parent comment author when a remote comment
  is created on a local article.

  The notification carries the comment, as a local reply's does: it is what
  the link on the notifications page points at, and it is part of the
  duplicate check — without it a second reply from the same remote account
  on the same article looked like the first one and was dropped.
  """
  def notify_remote_comment_created(article_id, parent_comment_id, remote_actor_id, comment_id) do
    article = Repo.get(Article, article_id)

    # Notify article author
    if article && article.user_id do
      Notification.create_notification(%{
        type: "reply_to_article",
        user_id: article.user_id,
        actor_remote_actor_id: remote_actor_id,
        article_id: article.id,
        comment_id: comment_id
      })
    end

    # Notify parent comment author (threaded reply)
    if parent_comment_id do
      parent = Repo.get(Comment, parent_comment_id)

      if parent && parent.user_id do
        Notification.create_notification(%{
          type: "reply_to_comment",
          user_id: parent.user_id,
          actor_remote_actor_id: remote_actor_id,
          article_id: article_id,
          comment_id: comment_id
        })
      end
    end
  end

  @doc """
  Tells the members watching any of `board_ids` that `article` arrived there
  (`watched_board_post`, ADR 0070).

  Called wherever an article is placed in a board — written here, arriving
  from another server, forwarded or cross-posted. Only threads: a board watch
  never reports comments. A watcher who cannot open the article is skipped,
  and so is one this article already reached as a mention.

  Best-effort work after the commit (`Federation.schedule_federation_task/1`):
  a busy board's watchers must not hold up the request that posted, and a
  notice lost to a restart is acceptable, as a push is.
  """
  def notify_board_watchers(%Article{} = article, board_ids) when is_list(board_ids) do
    Baudrate.Federation.schedule_federation_task(fn ->
      watchers = Baudrate.Content.Watches.board_watchers(board_ids)

      if watchers != [] do
        article = Repo.preload(article, :boards, force: true)
        told = already_told(article.id, nil, ~w(mention))

        for {user_id, board_id} <- watchers,
            user_id not in told,
            user_id != article.user_id,
            %{} = user <- [Auth.get_user(user_id)],
            ArticleHelpers.user_can_view_article?(article, user) do
          Notification.create_notification(
            actor_attrs(article)
            |> Map.merge(%{
              type: "watched_board_post",
              user_id: user_id,
              article_id: article.id,
              data: %{"board_id" => board_id}
            })
          )
        end
      end

      :ok
    end)
  end

  @doc """
  Tells the members watching `comment`'s thread that it was posted
  (`watched_thread_reply`, ADR 0070).

  Skips anyone the comment already reached as a reply or a mention — one
  event, one notice — and anyone who can no longer open the thread. A remote
  comment that is not public or unlisted is never announced, as it is never
  listed. Best-effort, like `notify_board_watchers/2`.
  """
  def notify_thread_watchers(%Comment{} = comment) do
    if comment.visibility in ["public", "unlisted"] and is_nil(comment.deleted_at) do
      Baudrate.Federation.schedule_federation_task(fn ->
        watchers = Baudrate.Content.Watches.watcher_ids_for_article(comment.article_id)

        if watchers != [] do
          article = Repo.get(Article, comment.article_id) |> Repo.preload(:boards)

          told =
            already_told(article.id, comment.id, ~w(reply_to_article reply_to_comment mention))

          for user_id <- watchers,
              user_id not in told,
              user_id != comment.user_id,
              %{} = user <- [Auth.get_user(user_id)],
              ArticleHelpers.user_can_view_article?(article, user) do
            Notification.create_notification(
              actor_attrs(comment)
              |> Map.merge(%{
                type: "watched_thread_reply",
                user_id: user_id,
                article_id: article.id,
                comment_id: comment.id
              })
            )
          end
        end

        :ok
      end)
    end

    :ok
  end

  # Who has already been told about this article or comment by a notice of
  # one of `types` — the watcher notice would be the same event twice.
  defp already_told(article_id, comment_id, types) do
    query =
      from(n in Baudrate.Notification.Notification,
        where: n.article_id == ^article_id and n.type in ^types,
        select: n.user_id
      )

    query =
      if comment_id,
        do: from(n in query, where: n.comment_id == ^comment_id),
        else: from(n in query, where: is_nil(n.comment_id))

    Repo.all(query)
  end

  defp actor_attrs(%{user_id: user_id}) when is_integer(user_id), do: %{actor_user_id: user_id}

  defp actor_attrs(%{remote_actor_id: remote_actor_id}) when is_integer(remote_actor_id),
    do: %{actor_remote_actor_id: remote_actor_id}

  defp actor_attrs(_), do: %{}

  @doc """
  Tells the author and the local voters of a poll that it has closed
  (ADR 0069). Called once per poll, by `Content.sweep_closed_polls/0`.

  The row carries the article and nothing else — no option, no count and no
  vote — so each recipient learns only that a poll they wrote or voted in is
  over. Anyone who can no longer open the article is skipped, as a mention
  is, and nobody is told twice.
  """
  def notify_poll_closed(%Article{} = article, user_ids) when is_list(user_ids) do
    article = Repo.preload(article, :boards)

    user_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn user_id ->
      with %{} = user <- Auth.get_user(user_id),
           true <- ArticleHelpers.user_can_view_article?(article, user) do
        Notification.create_notification(%{
          type: "poll_closed",
          user_id: user_id,
          article_id: article.id
        })
      end
    end)
  end

  @doc """
  Notifies all admin users when a new moderation report is created.
  """
  def notify_report_created(report_id) do
    report = Repo.get(Report, report_id)

    (Setup.staff_user_ids() ++ board_moderator_ids(report))
    |> Enum.uniq()
    |> Enum.each(fn user_id ->
      Notification.create_notification(%{
        type: "moderation_report",
        user_id: user_id,
        data: %{"report_id" => report_id}
      })
    end)
  end

  # Board moderators hear about reports on their own boards (1B); staff hear
  # about every report.
  defp board_moderator_ids(nil), do: []

  defp board_moderator_ids(%Report{article_id: nil, comment_id: nil}), do: []

  defp board_moderator_ids(%Report{article_id: article_id, comment_id: comment_id}) do
    article_id =
      article_id || Repo.one(from(c in Comment, where: c.id == ^comment_id, select: c.article_id))

    if article_id do
      Repo.all(
        from(bm in BoardModerator,
          join: ba in BoardArticle,
          on: ba.board_id == bm.board_id,
          where: ba.article_id == ^article_id,
          select: bm.user_id
        )
      )
    else
      []
    end
  end

  @doc """
  Tells a reporter that their report was reviewed (P1-D4).

  No details and no outcome: a reporter learns that staff looked at it,
  nothing about the decision. Dismissed reports say nothing at all, so only
  resolving calls this. Reports that arrived as federated Flags have no local
  reporter, and nobody is told about their own report on their own content.
  """
  @spec notify_report_reviewed(Report.t()) :: :ok
  def notify_report_reviewed(%Report{reporter_id: nil}), do: :ok

  def notify_report_reviewed(%Report{} = report) do
    Notification.create_notification(%{
      type: "report_reviewed",
      user_id: report.reporter_id,
      data: %{"report_id" => report.id}
    })

    :ok
  end

  @doc """
  Tells the people who can review a held post that it is waiting (ADR 0065):
  admins, global moderators, and the board moderators who moderate every
  board it would appear in. Always delivered, for `pending_registration`'s
  reason: a queue nobody is told about is a queue nobody empties.
  """
  @spec notify_post_held(Baudrate.Moderation.HeldPost.t()) :: :ok
  def notify_post_held(%Baudrate.Moderation.HeldPost{} = held) do
    (Setup.staff_user_ids() ++ Baudrate.Moderation.HeldPosts.board_reviewer_ids(held))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == held.user_id))
    |> Enum.each(fn user_id ->
      Notification.create_notification(%{
        type: "held_post",
        user_id: user_id,
        data: %{"held_post_id" => held.id, "kind" => held.kind}
      })
    end)

    :ok
  end

  @doc """
  Tells an author that a moderator approved their held post, which is now
  published. Actorless, so it names no moderator, and always delivered — it is
  about the recipient's own content (P1-D4).
  """
  @spec notify_post_approved(Baudrate.Moderation.HeldPost.t(), Article.t() | Comment.t()) :: :ok
  def notify_post_approved(held, %Article{} = article) do
    deliver_review(held.user_id, "post_approved", %{article_id: article.id})
  end

  def notify_post_approved(held, %Comment{} = comment) do
    deliver_review(held.user_id, "post_approved", %{
      article_id: comment.article_id,
      comment_id: comment.id
    })
  end

  @doc """
  Tells an author that a moderator declined to publish their held post. The
  note, if any, is on `/drafts` beside the text, not in the notification.
  """
  @spec notify_post_rejected(Baudrate.Moderation.HeldPost.t()) :: :ok
  def notify_post_rejected(held) do
    deliver_review(held.user_id, "post_rejected", %{data: %{"kind" => held.kind}})
  end

  defp deliver_review(user_id, type, attrs) do
    attrs
    |> Map.merge(%{type: type, user_id: user_id})
    |> Notification.create_notification()

    :ok
  end

  @doc """
  Tells staff that someone registered and is waiting to be let in.

  An approval queue nobody is told about is an approval queue nobody empties,
  so this is sent whenever registration leaves an account `pending`.
  """
  @spec notify_pending_registration(Baudrate.Setup.User.t()) :: :ok
  def notify_pending_registration(%Baudrate.Setup.User{} = user) do
    Enum.each(Setup.staff_user_ids(), fn staff_id ->
      Notification.create_notification(%{
        type: "pending_registration",
        user_id: staff_id,
        actor_user_id: user.id
      })
    end)

    :ok
  end

  @doc """
  Tells an author that a moderator removed their article or comment (P1-D4),
  with the reason category of the report it came from when there was one.

  Always delivered: this cannot be switched off in preferences. Content the
  author deleted themselves says nothing (the remover is the actor, and a
  notification is never sent to its own actor), and remote authors are not
  local users to notify.
  """
  @spec notify_content_removed(Article.t() | Comment.t(), integer(), String.t() | nil) :: :ok
  def notify_content_removed(content, removed_by_id, reason_category \\ nil)

  def notify_content_removed(%Article{} = article, removed_by_id, reason_category) do
    deliver_removal(article.user_id, removed_by_id, %{
      "content_type" => "article",
      "title" => article.title,
      "reason_category" => reason_category
    })
  end

  def notify_content_removed(%Comment{} = comment, removed_by_id, reason_category) do
    deliver_removal(comment.user_id, removed_by_id, %{
      "content_type" => "comment",
      "article_id" => comment.article_id,
      "reason_category" => reason_category
    })
  end

  defp deliver_removal(nil, _removed_by_id, _data), do: :ok

  defp deliver_removal(author_id, removed_by_id, data) do
    Notification.create_notification(%{
      type: "content_removed",
      user_id: author_id,
      actor_user_id: removed_by_id,
      data: data
    })

    :ok
  end

  @doc """
  Notifies the article author when their article receives a local boost.
  """
  def notify_local_article_boosted(article_id, booster_user_id) do
    article = Repo.get(Article, article_id)

    if article && article.user_id do
      Notification.create_notification(%{
        type: "article_boosted",
        user_id: article.user_id,
        actor_user_id: booster_user_id,
        article_id: article.id
      })
    end
  end

  @doc """
  Notifies the article author when their article receives a remote boost.
  """
  def notify_remote_article_boosted(article_id, remote_actor_id) do
    article = Repo.get(Article, article_id)

    if article && article.user_id do
      Notification.create_notification(%{
        type: "article_boosted",
        user_id: article.user_id,
        actor_remote_actor_id: remote_actor_id,
        article_id: article.id
      })
    end
  end

  @doc """
  Notifies the comment author when their comment receives a local boost.
  """
  def notify_local_comment_boosted(comment_id, booster_user_id) do
    comment = Repo.get(Comment, comment_id)

    if comment && comment.user_id do
      Notification.create_notification(%{
        type: "comment_boosted",
        user_id: comment.user_id,
        actor_user_id: booster_user_id,
        article_id: comment.article_id,
        comment_id: comment.id
      })
    end
  end

  @doc """
  Notifies the comment author when their comment receives a remote boost.
  """
  def notify_remote_comment_boosted(comment_id, remote_actor_id) do
    comment = Repo.get(Comment, comment_id)

    if comment && comment.user_id do
      Notification.create_notification(%{
        type: "comment_boosted",
        user_id: comment.user_id,
        actor_remote_actor_id: remote_actor_id,
        article_id: comment.article_id,
        comment_id: comment.id
      })
    end
  end

  @doc """
  Notifies the comment author when their comment receives a remote like.
  """
  def notify_remote_comment_liked(comment_id, remote_actor_id) do
    comment = Repo.get(Comment, comment_id)

    if comment && comment.user_id do
      Notification.create_notification(%{
        type: "comment_liked",
        user_id: comment.user_id,
        actor_remote_actor_id: remote_actor_id,
        article_id: comment.article_id,
        comment_id: comment.id
      })
    end
  end

  # --- Private helpers ---

  defp notify_mentions(body, actor_user_id, article_id, comment_id) do
    # `Mentions.extract/1`, not `Markdown.extract_mentions/1`: a member may be
    # named in the long form `@alice@this.host`, which is a local mention
    # written out in full and has to notify like any other (ADR 0051).
    usernames = Baudrate.Federation.Mentions.extract(body).local
    article = mentioned_article(article_id)

    Enum.each(usernames, fn username ->
      case Auth.get_user_by_username_ci(username) do
        # A deleted account has nobody to tell (ADR 0072).
        %{status: "deleted"} ->
          :ok

        %{id: user_id} = mentioned ->
          # A notification renders the article's title and a working permalink
          # (`NotificationsLive.target_title/1`), so mentioning someone from a
          # `min_role_to_view: "moderator"` board handed them the restricted
          # title — the same leak CLAUDE.md records as closed for
          # `/users/:name`, reached through another surface. The row-level
          # gate is the one to use, so it also covers boards whose role
          # changed after the mention was written.
          if is_nil(article) or ArticleHelpers.user_can_view_article?(article, mentioned) do
            Notification.create_notification(%{
              type: "mention",
              user_id: user_id,
              actor_user_id: actor_user_id,
              article_id: article_id,
              comment_id: comment_id
            })
          end

        nil ->
          :ok
      end
    end)
  end

  @doc """
  Tells every admin that the health report has checks failing (ADR 0044).

  `checks` is the sorted list of failing check names, e.g. `["backup",
  "disk"]`. Only the names travel: the reasons stay in the report, which is
  the authoritative place for them and needs no translating, and this way the
  notification cannot carry anything the report itself would refuse to
  (ADR 0035). Admins only — a moderator cannot fix a full disk.
  """
  @spec notify_health_alert([String.t()]) :: :ok
  def notify_health_alert(checks) when is_list(checks) do
    Enum.each(Setup.admin_user_ids(), fn admin_id ->
      Notification.create_notification(%{
        type: "health_alert",
        user_id: admin_id,
        data: %{"checks" => checks}
      })
    end)

    :ok
  end

  @doc """
  Tells every admin that every health check passes again (ADR 0044).

  Sent only after an alert, so a quiet instance stays quiet.
  """
  @spec notify_health_recovered() :: :ok
  def notify_health_recovered do
    Enum.each(Setup.admin_user_ids(), fn admin_id ->
      Notification.create_notification(%{
        type: "health_recovered",
        user_id: admin_id
      })
    end)

    :ok
  end

  defp mentioned_article(nil), do: nil

  defp mentioned_article(article_id) do
    case Repo.get(Article, article_id) do
      nil -> nil
      article -> Repo.preload(article, [:boards, :remote_actor])
    end
  end
end
