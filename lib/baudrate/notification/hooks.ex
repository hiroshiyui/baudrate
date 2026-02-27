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
    * `notify_remote_article_liked/2` — article_liked
    * `notify_article_forwarded/2` — article_forwarded
    * `notify_local_follow/2` — new_follower
    * `notify_remote_follow/2` — new_follower (remote actor)
    * `notify_remote_comment_created/3` — reply_to_article, reply_to_comment
    * `notify_report_created/1` — moderation_report (all admins)
  """

  alias Baudrate.{Auth, Notification, Repo, Setup}
  alias Baudrate.Content.{Article, Comment, Markdown}

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
    admin_ids = Setup.admin_user_ids()

    Enum.each(admin_ids, fn admin_id ->
      Notification.create_notification(%{
        type: "moderation_report",
        user_id: admin_id,
        data: %{"report_id" => report_id}
      })
    end)
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
