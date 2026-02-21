defmodule Baudrate.Federation.Publisher do
  @moduledoc """
  Builds ActivityStreams JSON for outgoing local activities and enqueues
  them for delivery to remote followers.

  Each `build_*` function returns a `{activity_map, actor_uri}` tuple.
  The `publish_*` convenience functions build the activity and call
  `Delivery.enqueue_for_article/2` to fan out to follower inboxes.

  Outbound Note objects include `to`/`cc` addressing for Mastodon
  compatibility — Mastodon requires these fields to determine visibility.
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
      "object" => %{
        "id" => article_uri,
        "type" => "Tombstone"
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
    for board <- article.boards, board.visibility == "public" do
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
  Publishes an `Update(Article)` activity to all relevant followers.
  """
  def publish_article_updated(article) do
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_update_article(article)
    Delivery.enqueue_for_article(activity, actor_uri, article)
  end
end
