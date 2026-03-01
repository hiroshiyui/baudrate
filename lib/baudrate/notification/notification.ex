defmodule Baudrate.Notification.Notification do
  @moduledoc """
  Schema for user notifications.

  Each notification targets a single user (`user_id`) and optionally references
  the actor who triggered it (either a local `actor_user_id` or a remote
  `actor_remote_actor_id`), plus optional article/comment context.

  ## Types

    * `reply_to_article` — someone replied to your article
    * `reply_to_comment` — someone replied to your comment
    * `mention` — someone @mentioned you
    * `new_follower` — someone followed you
    * `article_liked` — someone liked your article
    * `comment_liked` — someone liked your comment
    * `article_forwarded` — your article was forwarded to another board
    * `moderation_report` — a new moderation report (admins only)
    * `admin_announcement` — announcement from an admin

  ## Deduplication

  Unique indexes on `(user_id, type, actor_*, article_id, comment_id)` prevent
  duplicate notifications for the same event. On conflict,
  `Notification.create_notification/1` returns `{:ok, :duplicate}`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.{Article, Comment}
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Setup.User

  @valid_types ~w(
    reply_to_article
    reply_to_comment
    mention
    new_follower
    article_liked
    comment_liked
    article_forwarded
    moderation_report
    admin_announcement
  )

  @doc "Returns the list of valid notification type strings."
  def valid_types, do: @valid_types

  schema "notifications" do
    field :type, :string
    field :read, :boolean, default: false
    field :data, :map, default: %{}

    belongs_to :user, User
    belongs_to :actor_user, User
    belongs_to :actor_remote_actor, RemoteActor
    belongs_to :article, Article
    belongs_to :comment, Comment

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a notification."
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [
      :type,
      :read,
      :data,
      :user_id,
      :actor_user_id,
      :actor_remote_actor_id,
      :article_id,
      :comment_id
    ])
    |> validate_required([:type, :user_id])
    |> validate_inclusion(:type, @valid_types)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:actor_user_id)
    |> foreign_key_constraint(:actor_remote_actor_id)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:comment_id)
    |> unique_constraint([:user_id, :type, :actor_user_id, :article_id, :comment_id],
      name: :notifications_dedup_local_index
    )
    |> unique_constraint(
      [:user_id, :type, :actor_remote_actor_id, :article_id, :comment_id],
      name: :notifications_dedup_remote_index
    )
  end
end
