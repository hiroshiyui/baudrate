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
    * `notify_remote_comment_created/3` — reply_to_article, reply_to_comment
    * `notify_report_created/1` — moderation_report (all admins)
    * `notify_account_security/3` — security_key_added, security_key_removed,
      totp_enabled, totp_disabled, password_changed, signed_out_everywhere,
      totp_login_failed, account_alias_added, account_alias_removed,
      account_move_requested, account_move_cancelled, account_move_failed,
      account_moved, account_redirect_removed, data_export_*
    * `notify_actor_moved/3` — actor_moved
    * `notify_board_actor_moved/2` — board_actor_moved (all admins)
  """

  alias Baudrate.{Auth, Notification, Repo, Setup}
  import Ecto.Query, only: [from: 2]

  alias Baudrate.Content.{Article, BoardArticle, BoardModerator, Comment, Markdown}
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
  Notifies the followed user when a local user follows them.
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
  """
  def notify_remote_comment_created(article_id, parent_comment_id, remote_actor_id) do
    article = Repo.get(Article, article_id)

    # Notify article author
    if article && article.user_id do
      Notification.create_notification(%{
        type: "reply_to_article",
        user_id: article.user_id,
        actor_remote_actor_id: remote_actor_id,
        article_id: article.id
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
          article_id: article_id
        })
      end
    end
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
    usernames = Markdown.extract_mentions(body)

    Enum.each(usernames, fn username ->
      case Auth.get_user_by_username_ci(username) do
        %{id: user_id} ->
          Notification.create_notification(%{
            type: "mention",
            user_id: user_id,
            actor_user_id: actor_user_id,
            article_id: article_id,
            comment_id: comment_id
          })

        nil ->
          :ok
      end
    end)
  end
end
