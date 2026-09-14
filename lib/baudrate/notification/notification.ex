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
    * `article_boosted` — someone boosted your article
    * `comment_boosted` — someone boosted your comment
    * `article_forwarded` — your article was forwarded to another board
    * `moderation_report` — a new moderation report (admins only)
    * `admin_announcement` — announcement from an admin

  ### Account security notices

  These types have no actor and are always delivered: they bypass the
  per-type in-app and web push preferences (see `security_types/0`). They let
  a user notice a change they did not make to how their account signs in
  (second factors, password, sessions); see ADR 0022 and ADR 0023.

    * `security_key_added` — a WebAuthn security key was registered (`data.label`)
    * `security_key_removed` — a WebAuthn security key was removed (`data.label`)
    * `totp_enabled` — TOTP two-factor authentication was set up
    * `totp_disabled` — TOTP two-factor authentication was turned off
    * `password_changed` — the account password was changed while signed in
    * `signed_out_everywhere` — all other sessions were signed out (`data.count`)
    * `data_export_requested` — a data export was requested (`data.ready_at`, `data.browser`)
    * `data_export_ready` — the export can be downloaded (`data.expires_at`)
    * `data_export_downloaded` — the export was downloaded (`data.count`, `data.remaining`)
    * `data_export_cancelled` — an export request was cancelled (`data.reason`)

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
    article_boosted
    comment_boosted
    article_forwarded
    moderation_report
    admin_announcement
    security_key_added
    security_key_removed
    totp_enabled
    totp_disabled
    password_changed
    signed_out_everywhere
    data_export_requested
    data_export_ready
    data_export_downloaded
    data_export_cancelled
  )

  @security_types ~w(
    security_key_added
    security_key_removed
    totp_enabled
    totp_disabled
    password_changed
    signed_out_everywhere
    data_export_requested
    data_export_ready
    data_export_downloaded
    data_export_cancelled
  )

  @doc "Returns the list of valid notification type strings."
  def valid_types, do: @valid_types

  @doc """
  Returns the account security notice types. These are always delivered and
  cannot be turned off through notification preferences.
  """
  def security_types, do: @security_types

  @doc """
  Returns the notification types a user can turn on or off in their
  preferences: every valid type except the account security notices.

  This is the single source for both the preferences changeset
  (`User.notification_preferences_changeset/2`) and the preferences table on
  `/profile`. The two used to be separate lists, and they drifted apart: the
  page offered toggles the changeset rejected.
  """
  def configurable_types, do: @valid_types -- @security_types

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
