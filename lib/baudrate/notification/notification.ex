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
    * `actor_moved` — an account the user followed moved; the user now follows
      the new account (`data.label`, `data.url`, ADR 0025)
    * `board_actor_moved` — a remote account followed by boards moved; board
      follows were not switched over (admins only; `data.label`, `data.boards`)

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
    * `totp_login_failed` — the correct password was entered but the TOTP code
      kept failing at login, so someone else may know the password (ADR 0024)
    * `account_alias_added` / `account_alias_removed` — an account alias
      (`alsoKnownAs`) was added or removed (`data.label`, ADR 0025)
    * `account_move_requested` — a move of the account was requested; it is
      sent after 24 hours (`data.label`, `data.send_after`, `data.browser`)
    * `account_move_cancelled` — a pending move was cancelled (`data.reason`)
    * `account_move_failed` — the send-time re-check refused a move
      (`data.reason`, `data.label`)
    * `account_moved` — the move was sent; the account is now read-only
      (`data.label`)
    * `account_redirect_removed` — the redirect of a moved account was removed
      (`data.label`)
    * `data_export_requested` — a data export was requested (`data.ready_at`, `data.browser`)
    * `data_export_ready` — the export can be downloaded (`data.expires_at`)
    * `data_export_downloaded` — the export was downloaded (`data.count`, `data.remaining`)
    * `data_export_cancelled` — an export request was cancelled (`data.reason`)
    * `recovery_codes_regenerated` — a fresh set of recovery codes was issued
      and every earlier code stopped working (`data.count`)
    * `recovery_contact_added` / `recovery_contact_removed` — a recovery
      contact was registered or taken off the account (`data.label`, ADR 0058)
    * `recovery_contact_verified` — an admin confirmed a recovery contact
      (`data.label`)
    * `account_reset_issued` — an admin issued a recovery link for this
      account (`data.expires_at`, `data.second_factors_cleared`). Sent when
      the link is created, so a member who did *not* ask for one and still has
      a session finds out while it is outstanding
    * `account_reset_used` — an admin-issued reset link was redeemed: the
      password was replaced and every session signed out
      (`data.second_factors_cleared`)
    * `registration_approved` — a pending account was approved and may post

  ### Operational notices

  Also actorless and always delivered, but sent to admins rather than to the
  account they concern (ADR 0044). An operator who muted announcements still
  has to hear that the instance stopped backing itself up.

    * `health_alert` — one or more health checks have been failing for over an
      hour (`data.checks`, the failing check names)
    * `health_recovered` — every check passes again
    * `pending_registration` — somebody registered and is waiting for approval
      (`actor_user_id`). Always delivered for the same reason as the rest of
      this group: an approval queue nobody is told about is an approval queue
      nobody empties.
    * `held_post` — a post is waiting for review (`data.held_post_id`,
      `data.kind`), sent to whoever can review it (ADR 0065). Always
      delivered, for the same reason.

  ### Held posts, for their author

  Moderation notices about the recipient's own content, always delivered
  like `content_removed`, and actorless, so they name no moderator.

    * `post_approved` — a held post was approved and is published
      (`article_id`, and `comment_id` for a comment)
    * `post_rejected` — a moderator declined to publish a held post
      (`data.kind`); the text and any note stay on `/drafts`

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
    report_reviewed
    content_removed
    admin_announcement
    actor_moved
    board_actor_moved
    security_key_added
    security_key_removed
    totp_enabled
    totp_disabled
    password_changed
    signed_out_everywhere
    totp_login_failed
    account_alias_added
    account_alias_removed
    account_move_requested
    account_move_cancelled
    account_move_failed
    account_moved
    account_redirect_removed
    data_export_requested
    data_export_ready
    data_export_downloaded
    data_export_cancelled
    recovery_codes_regenerated
    recovery_contact_added
    recovery_contact_removed
    recovery_contact_verified
    account_reset_issued
    account_reset_used
    registration_approved
    sanction_applied
    sanction_lifted
    sanction_ended
    pending_registration
    health_alert
    health_recovered
    held_post
    post_approved
    post_rejected
  )

  @security_types ~w(
    security_key_added
    security_key_removed
    totp_enabled
    totp_disabled
    password_changed
    signed_out_everywhere
    totp_login_failed
    account_alias_added
    account_alias_removed
    account_move_requested
    account_move_cancelled
    account_move_failed
    account_moved
    account_redirect_removed
    data_export_requested
    data_export_ready
    data_export_downloaded
    data_export_cancelled
    recovery_codes_regenerated
    recovery_contact_added
    recovery_contact_removed
    recovery_contact_verified
    account_reset_issued
    account_reset_used
    registration_approved
  )

  # Moderation notices about the recipient's own content or account. Like
  # account security notices they are always delivered: someone must not be
  # able to switch off being told their post was removed, or that their
  # account was silenced, why and until when (P1-D4).
  @moderation_notice_types ~w(content_removed sanction_applied sanction_lifted sanction_ended post_approved post_rejected)

  # Operational notices to admins (ADR 0044). Always delivered for the same
  # reason as the other two classes: the person who would switch these off is
  # exactly the person who has to act on them, and an alert that can be muted
  # by accident is not an alert.
  @operational_notice_types ~w(health_alert health_recovered pending_registration held_post)

  @doc "Returns the list of valid notification type strings."
  def valid_types, do: @valid_types

  @doc """
  Returns the account security notice types. These are always delivered and
  cannot be turned off through notification preferences.
  """
  def security_types, do: @security_types

  @doc """
  Types that ignore notification preferences: account security notices,
  moderation notices about the recipient's own content, and the operational
  notices admins get about the instance itself.
  """
  def always_delivered_types,
    do: @security_types ++ @moderation_notice_types ++ @operational_notice_types

  @doc """
  Returns the notification types a user can turn on or off in their
  preferences: every valid type except the always-delivered ones.

  This is the single source for both the preferences changeset
  (`User.notification_preferences_changeset/2`) and the preferences table on
  `/profile`. The two used to be separate lists, and they drifted apart: the
  page offered toggles the changeset rejected.
  """
  def configurable_types, do: @valid_types -- always_delivered_types()

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
