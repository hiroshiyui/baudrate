defmodule Baudrate.Federation.Publisher do
  @moduledoc """
  Builds ActivityStreams JSON for outgoing local activities and enqueues
  them for delivery to remote followers.

  Each `build_*` function returns a `{activity_map, actor_uri}` tuple.
  The `publish_*` convenience functions build the activity and call
  `Delivery.enqueue_for_article/2` to fan out to follower inboxes.

  Outbound Note objects include `to`/`cc` addressing for Mastodon
  compatibility — Mastodon requires these fields to determine visibility.

  Direct message activities use restricted addressing (only the recipient
  in `to`, no `as:Public`, no followers collection) and are delivered to
  the recipient's personal inbox (not shared inbox) for privacy.
  """

  alias Baudrate.Federation
  alias Baudrate.Federation.Delivery
  alias Baudrate.Repo

  @as_context "https://www.w3.org/ns/activitystreams"
  @as_public "https://www.w3.org/ns/activitystreams#Public"

  # --- Activity Builders ---

  @doc """
  Builds a `Create(Article)` activity for a newly published article.

  Returns `{activity_map, actor_uri}`.
  """
  def build_create_article(article) do
    article = Repo.preload(article, [:boards, :user])
    actor_uri = Federation.actor_uri(:user, article.user.username)
    object = Federation.article_object(article)

    activity = %{
      "@context" => @as_context,
      "id" => "#{actor_uri}#create-#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => actor_uri,
      "published" => DateTime.to_iso8601(article.inserted_at),
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"],
      "object" => object
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Delete` activity for a soft-deleted article.

  Returns `{activity_map, actor_uri}`.
  """
  def build_delete_article(article) do
    article = Repo.preload(article, [:user])
    actor_uri = Federation.actor_uri(:user, article.user.username)
    article_uri = Federation.actor_uri(:article, article.slug)

    activity = %{
      "@context" => @as_context,
      "id" => "#{actor_uri}#delete-#{System.unique_integer([:positive])}",
      "type" => "Delete",
      "actor" => actor_uri,
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"],
      "object" => %{
        "id" => article_uri,
        "type" => "Tombstone",
        "formerType" => "Article"
      }
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Announce` activity from a board actor wrapping an article URI.

  Returns `{activity_map, board_actor_uri}`.
  """
  def build_announce_article(article, board) do
    board_uri = Federation.actor_uri(:board, board.slug)
    article_uri = Federation.actor_uri(:article, article.slug)

    activity = %{
      "@context" => @as_context,
      "id" => "#{board_uri}#announce-#{System.unique_integer([:positive])}",
      "type" => "Announce",
      "actor" => board_uri,
      "published" => DateTime.to_iso8601(article.inserted_at),
      "to" => [@as_public],
      "cc" => ["#{board_uri}/followers"],
      "object" => article_uri
    }

    {activity, board_uri}
  end

  @doc """
  Builds an `Update(Article)` activity for an edited article.

  Returns `{activity_map, actor_uri}`.
  """
  def build_update_article(article) do
    article = Repo.preload(article, [:boards, :user])
    actor_uri = Federation.actor_uri(:user, article.user.username)
    object = Federation.article_object(article)

    activity = %{
      "@context" => @as_context,
      "id" => "#{actor_uri}#update-#{System.unique_integer([:positive])}",
      "type" => "Update",
      "actor" => actor_uri,
      "published" => DateTime.to_iso8601(article.updated_at),
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"],
      "object" => object
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Create(Note)` activity for a local comment.

  Returns `{activity_map, actor_uri}`.
  """
  def build_create_comment(comment, article) do
    comment = Repo.preload(comment, [:user])
    article = Repo.preload(article, [:user])
    actor_uri = Federation.actor_uri(:user, comment.user.username)
    article_uri = Federation.actor_uri(:article, article.slug)

    activity = %{
      "@context" => @as_context,
      "id" => "#{actor_uri}#create-#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => actor_uri,
      "published" => DateTime.to_iso8601(comment.inserted_at),
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"],
      "object" => %{
        "id" => "#{actor_uri}#note-#{comment.id}",
        "type" => "Note",
        "content" => comment.body_html || comment.body,
        "attributedTo" => actor_uri,
        "inReplyTo" => article_uri,
        "published" => DateTime.to_iso8601(comment.inserted_at),
        "to" => [@as_public],
        "cc" => ["#{actor_uri}/followers"]
      }
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Flag` activity for reporting remote content to an instance admin.

  Returns `flag_map`.
  """
  def build_flag(remote_actor, content_ap_ids, reason) do
    site_uri = Federation.actor_uri(:site, nil)

    %{
      "@context" => @as_context,
      "id" => "#{site_uri}#flag-#{System.unique_integer([:positive])}",
      "type" => "Flag",
      "actor" => site_uri,
      "object" => [remote_actor.ap_id | content_ap_ids],
      "content" => reason
    }
  end

  @doc """
  Builds a `Block` activity from a local user to a remote actor.

  Returns `{activity_map, actor_uri}`.
  """
  def build_block(user, target_ap_id) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => @as_context,
      "id" => "#{actor_uri}#block-#{System.unique_integer([:positive])}",
      "type" => "Block",
      "actor" => actor_uri,
      "object" => target_ap_id
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Undo(Block)` activity.

  Returns `{activity_map, actor_uri}`.
  """
  def build_undo_block(user, target_ap_id) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => @as_context,
      "id" => "#{actor_uri}#undo-block-#{System.unique_integer([:positive])}",
      "type" => "Undo",
      "actor" => actor_uri,
      "object" => %{
        "type" => "Block",
        "actor" => actor_uri,
        "object" => target_ap_id
      }
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Follow` activity from a local user to a remote actor.

  Returns `{activity_map, actor_uri}`.
  """
  def build_follow(user, remote_actor, follow_ap_id) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => @as_context,
      "id" => follow_ap_id,
      "type" => "Follow",
      "actor" => actor_uri,
      "object" => remote_actor.ap_id
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Undo(Follow)` activity for cancelling an outbound follow.

  Embeds the original Follow's AP ID as the inner object.
  Returns `{activity_map, actor_uri}`.
  """
  def build_undo_follow(user, user_follow) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => @as_context,
      "id" => "#{actor_uri}#undo-follow-#{System.unique_integer([:positive])}",
      "type" => "Undo",
      "actor" => actor_uri,
      "object" => %{
        "id" => user_follow.ap_id,
        "type" => "Follow",
        "actor" => actor_uri,
        "object" => user_follow.remote_actor.ap_id
      }
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Follow` activity from a board actor to a remote actor.

  Returns `{activity_map, board_actor_uri}`.
  """
  def build_board_follow(board, remote_actor, follow_ap_id) do
    board_uri = Federation.actor_uri(:board, board.slug)

    activity = %{
      "@context" => @as_context,
      "id" => follow_ap_id,
      "type" => "Follow",
      "actor" => board_uri,
      "object" => remote_actor.ap_id
    }

    {activity, board_uri}
  end

  @doc """
  Builds an `Undo(Follow)` activity from a board actor for cancelling an outbound follow.

  Embeds the original Follow's AP ID as the inner object.
  Returns `{activity_map, board_actor_uri}`.
  """
  def build_board_undo_follow(board, board_follow) do
    board_uri = Federation.actor_uri(:board, board.slug)

    activity = %{
      "@context" => @as_context,
      "id" => "#{board_uri}#undo-follow-#{System.unique_integer([:positive])}",
      "type" => "Undo",
      "actor" => board_uri,
      "object" => %{
        "id" => board_follow.ap_id,
        "type" => "Follow",
        "actor" => board_uri,
        "object" => board_follow.remote_actor.ap_id
      }
    }

    {activity, board_uri}
  end

  @doc """
  Builds an `Update` activity for an actor (used for key rotation distribution).

  Returns `{activity_map, actor_uri}`.
  """
  def build_update_actor(actor_type, entity) do
    {actor_uri, actor_json} =
      case actor_type do
        :user ->
          uri = Federation.actor_uri(:user, entity.username)
          {uri, Federation.user_actor(entity)}

        :board ->
          uri = Federation.actor_uri(:board, entity.slug)
          {uri, Federation.board_actor(entity)}

        :site ->
          uri = Federation.actor_uri(:site, nil)
          {uri, Federation.site_actor()}
      end

    activity = %{
      "@context" => @as_context,
      "id" => "#{actor_uri}#update-actor-#{System.unique_integer([:positive])}",
      "type" => "Update",
      "actor" => actor_uri,
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"],
      "object" => actor_json
    }

    {activity, actor_uri}
  end

  @doc """
  Publishes an `Update` activity for an actor to all followers.
  Used after key rotation to distribute the new public key.
  """
  def publish_key_rotation(actor_type, entity) do
    {activity, actor_uri} = build_update_actor(actor_type, entity)
    Delivery.enqueue_for_followers(activity, actor_uri)
  end

  # --- Publish Convenience Functions ---

  @doc """
  Publishes a `Create(Article)` activity to all relevant followers.

  Enqueues delivery to followers of the article's author and to
  followers of all public boards the article is posted to. Also
  enqueues `Announce` activities from each board actor to the board's
  followers.
  """
  def publish_article_created(article) do
    article = Repo.preload(article, [:boards, :user])

    # Create(Article) from user → user's followers + board followers
    {activity, actor_uri} = build_create_article(article)
    Delivery.enqueue_for_article(activity, actor_uri, article)

    # Announce from each public board → board's followers
    for board <- article.boards, board.min_role_to_view == "guest" do
      {announce, board_uri} = build_announce_article(article, board)
      Delivery.enqueue_for_followers(announce, board_uri)
    end

    :ok
  end

  @doc """
  Publishes a `Delete` activity to all relevant followers.
  """
  def publish_article_deleted(article) do
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_delete_article(article)
    Delivery.enqueue_for_article(activity, actor_uri, article)
  end

  @doc """
  Publishes a `Create(Note)` activity for a local comment to all relevant followers.
  """
  def publish_comment_created(comment, article) do
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_create_comment(comment, article)
    Delivery.enqueue_for_article(activity, actor_uri, article)
  end

  @doc """
  Publishes an `Update(Article)` activity to all relevant followers.
  """
  def publish_article_updated(article) do
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_update_article(article)
    Delivery.enqueue_for_article(activity, actor_uri, article)
  end

  # --- Direct Message Builders ---

  @doc """
  Builds a `Create(Note)` activity for a direct message.

  Addresses only the recipient in `to` (no public, no followers collection).
  Includes `Mention` tag and `context`/`conversation` fields for Mastodon compat.

  Returns `{activity_map, actor_uri}`.
  """
  def build_create_dm(message, conversation, sender_user) do
    actor_uri = Federation.actor_uri(:user, sender_user.username)
    conversation = Repo.preload(conversation, [:remote_actor_b, :user_b])

    recipient_uri = resolve_dm_recipient_uri(conversation, sender_user.id)
    recipient_acct = resolve_dm_recipient_acct(conversation, sender_user.id)

    message_uri = "#{actor_uri}#dm-#{message.id}"

    object =
      %{
        "id" => message_uri,
        "type" => "Note",
        "content" => message.body_html || message.body,
        "attributedTo" => actor_uri,
        "published" => DateTime.to_iso8601(message.inserted_at),
        "to" => [recipient_uri],
        "tag" => [
          %{
            "type" => "Mention",
            "href" => recipient_uri,
            "name" => recipient_acct
          }
        ],
        "context" => conversation.ap_context,
        "conversation" => conversation.ap_context
      }
      |> maybe_add_in_reply_to(message)

    activity = %{
      "@context" => @as_context,
      "id" => "#{actor_uri}#create-dm-#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => actor_uri,
      "published" => DateTime.to_iso8601(message.inserted_at),
      "to" => [recipient_uri],
      "object" => object
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Delete` activity with `Tombstone` for a deleted DM.

  Returns `{activity_map, actor_uri}`.
  """
  def build_delete_dm(message, sender_user, conversation) do
    actor_uri = Federation.actor_uri(:user, sender_user.username)
    message_uri = "#{actor_uri}#dm-#{message.id}"
    recipient_uri = resolve_dm_recipient_uri(conversation, sender_user.id)

    activity = %{
      "@context" => @as_context,
      "id" => "#{actor_uri}#delete-dm-#{System.unique_integer([:positive])}",
      "type" => "Delete",
      "actor" => actor_uri,
      "to" => [recipient_uri],
      "object" => %{
        "id" => message_uri,
        "type" => "Tombstone",
        "formerType" => "Note"
      }
    }

    {activity, actor_uri}
  end

  # --- Direct Message Publish Convenience Functions ---

  @doc """
  Publishes a `Create(Note)` DM activity to the remote recipient's personal inbox.

  Only delivers if the other participant is a `%RemoteActor{}`.
  Uses the personal inbox (NOT shared inbox) for DM privacy.
  """
  def publish_dm_created(message, conversation, sender_user) do
    conversation = Repo.preload(conversation, [:remote_actor_b])

    if conversation.remote_actor_b do
      {activity, actor_uri} = build_create_dm(message, conversation, sender_user)
      # Use personal inbox for DM privacy, not shared inbox
      Delivery.enqueue(activity, actor_uri, [conversation.remote_actor_b.inbox])
    else
      {:ok, 0}
    end
  end

  @doc """
  Publishes a `Delete` DM activity to the remote recipient's personal inbox.
  """
  def publish_dm_deleted(message, sender_user, conversation) do
    conversation = Repo.preload(conversation, [:remote_actor_b])

    if conversation.remote_actor_b do
      {activity, actor_uri} = build_delete_dm(message, sender_user, conversation)
      Delivery.enqueue(activity, actor_uri, [conversation.remote_actor_b.inbox])
    else
      {:ok, 0}
    end
  end

  # --- DM Helpers ---

  defp resolve_dm_recipient_uri(conversation, sender_user_id) do
    conversation = Repo.preload(conversation, [:user_a, :user_b, :remote_actor_b])

    cond do
      conversation.remote_actor_b && conversation.user_a_id == sender_user_id ->
        conversation.remote_actor_b.ap_id

      conversation.user_b && conversation.user_b_id != sender_user_id ->
        Federation.actor_uri(:user, conversation.user_b.username)

      conversation.user_a && conversation.user_a_id != sender_user_id ->
        Federation.actor_uri(:user, conversation.user_a.username)

      true ->
        nil
    end
  end

  defp resolve_dm_recipient_acct(conversation, sender_user_id) do
    conversation = Repo.preload(conversation, [:user_a, :user_b, :remote_actor_b])

    cond do
      conversation.remote_actor_b && conversation.user_a_id == sender_user_id ->
        "@#{conversation.remote_actor_b.username}@#{conversation.remote_actor_b.domain}"

      conversation.user_b && conversation.user_b_id != sender_user_id ->
        "@#{conversation.user_b.username}"

      conversation.user_a && conversation.user_a_id != sender_user_id ->
        "@#{conversation.user_a.username}"

      true ->
        ""
    end
  end

  defp maybe_add_in_reply_to(object, %{ap_in_reply_to: in_reply_to})
       when is_binary(in_reply_to) and in_reply_to != "" do
    Map.put(object, "inReplyTo", in_reply_to)
  end

  defp maybe_add_in_reply_to(object, _message), do: object
end
