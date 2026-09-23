defmodule Baudrate.Setup.User do
  @moduledoc """
  Schema for users stored in the `users` table.

  ## Password Policy

  Enforced by `registration_changeset/2`:

    * Minimum 12 characters, maximum 72 (bcrypt limit)
    * Must contain: lowercase, uppercase, digit, and special character
    * Passwords are hashed with bcrypt before storage; the plaintext is
      deleted from the changeset after hashing

  ## TOTP Fields

    * `totp_secret` — AES-256-GCM encrypted TOTP secret (binary), or `nil`
      if TOTP has not been enabled. Never stores the raw secret.
    * `totp_enabled` — boolean flag; when `true`, login requires TOTP verification
    * `totp_enabled_at` — when TOTP was last enabled (`nil` while disabled). Lets
      features refuse a freshly enrolled factor (see
      `Baudrate.Auth.SecondFactor.totp_enabled_for_at_least?/2`, ADR 0023).
      Accounts that had TOTP before the column existed were backfilled with
      the migration time.
    * `totp_last_used_step` — the most recent TOTP time step (unix time div 30)
      accepted for this account, or `nil`. A code is accepted only for a later
      step, so each code works once (`Baudrate.Auth.SecondFactor.verify_totp_code/3`,
      ADR 0024). Cleared when TOTP is disabled.

  ## Account Migration Fields (ADR 0025)

    * `also_known_as` — actor ids of other accounts this user claims
      (`alsoKnownAs`). A remote account can move here only if it is listed.
      Changed through `Baudrate.AccountMigration`, never cast from user params.
    * `moved_to` — actor id this account moved to, set when the `Move` was
      sent. While set, the account is read-only
      (`Baudrate.AccountMigration.moved?/1`).
    * `moved_at` — when the `Move` was sent

  ## ActivityPub Fields

    * `ap_public_key` — PEM-encoded RSA public key for ActivityPub federation
    * `ap_private_key_encrypted` — AES-256-GCM encrypted PEM-encoded RSA private key

  ## Status

    * `"active"` — fully functional account (default)
    * `"pending"` — awaiting admin approval; can log in, browse,
      and update profile (avatar, bio, signature, display name),
      but cannot create articles or comments
    * `"banned"` — account suspended by an admin; cannot log in

  ## Ban Fields

    * `banned_at` — UTC timestamp of when the ban was applied
    * `ban_reason` — optional text reason provided by the admin

  ## Locale Preferences

    * `preferred_locales` — ordered list of locale codes (e.g. `["zh_TW", "en"]`).
      When non-empty, the first matching known Gettext locale is used instead of
      the browser's `Accept-Language` header. Validated by `locale_changeset/2`.

  ## Direct Message Access

    * `dm_access` — controls who can send DMs to this user:
      `"anyone"` (default), `"followers"` (accounts that follow this user, here
      or on another instance), or `"nobody"`. An account still under the
      limits on new accounts reaches fewer people than this admits (ADR 0064).

  ## Display Name

    * `display_name` — optional human-friendly display name (max 64 characters).
      Sanitized on write: HTML tags stripped, control characters and bidi overrides
      removed, whitespace normalized. Mapped to the ActivityPub `name` field on the
      Person actor. Falls back to `username` for display when `nil`.

  ## Bio

    * `bio` — plaintext bio/about-me text (max 500 characters). Supports hashtag
      linkification for display. Mapped to the ActivityPub `summary` field on the
      Person actor. Validated by `bio_changeset/2`.

  ## Notification Preferences

    * `notification_preferences` — map of per-type notification settings.
      Keys are notification type strings (e.g. `"mention"`), values are maps
      with boolean flags like `%{"in_app" => false}`. Missing types default
      to enabled (`in_app: true`). Validated by `notification_preferences_changeset/2`.

  ## Profile Fields

    * `profile_fields` — list of up to 4 custom key-value metadata pairs
      (e.g. website, location). Each entry is a map with `"name"` (max 255 chars)
      and `"value"` (max 2048 chars) string keys. Stored as a JSONB array.
      Published as `attachment` entries of type `PropertyValue` on the AP actor.
      Validated by `profile_fields_changeset/2`.

  ## Invite Chain Tracking

    * `invited_by_id` — references the user who generated the invite code used
      during registration. `nil` for users who registered via open/approval modes.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  schema "users" do
    field :username, :string
    field :display_name, :string
    field :hashed_password, :string
    field :totp_secret, :binary
    field :totp_enabled, :boolean, default: false
    field :totp_enabled_at, :utc_datetime
    field :totp_last_used_step, :integer
    field :also_known_as, {:array, :string}, default: []
    field :moved_to, :string
    field :moved_at, :utc_datetime
    field :avatar_id, :string
    field :status, :string, default: "active"
    field :preferred_locales, {:array, :string}, default: []
    field :banned_at, :utc_datetime
    field :ban_reason, :string
    field :ap_public_key, :string
    field :ap_private_key_encrypted, :binary
    field :signature, :string
    field :bio, :string
    field :dm_access, :string, default: "anyone"
    # The zone this member's timestamps are shown in; nil means the site's
    # setting (`BaudrateWeb.TimeZone`). Written only by `time_zone_changeset/2`.
    field :time_zone, :string
    field :notification_preferences, :map, default: %{}
    # Privacy settings (ADR 0073), each written only by its own changeset.
    # Words that collapse other people's posts in this member's own views.
    field :muted_keywords, {:array, :map}, default: []
    # A new follower waits for the member's approval.
    field :manually_approves_followers, :boolean, default: false
    # Off: noindex, left out of the sitemap and the member search.
    field :discoverable, :boolean, default: true
    field :is_bot, :boolean, default: false
    field :profile_fields, {:array, :map}, default: []
    # The day this account last signed in, for NodeInfo's active-user counts.
    # A date rather than a timestamp on purpose: the question is which month
    # somebody was last here, and a timestamp would record what time of day
    # they read the site for six months. Never cast from params — `Sessions`
    # stamps it, and only when it changes.
    field :last_active_on, :date

    # Which version of the terms this account accepted, and when. Deliberately
    # outside every `cast/3` list: a member who could set these in the
    # registration params could accept a version that does not exist yet and
    # never be asked again.
    field :terms_accepted_at, :utc_datetime
    field :terms_version, :integer, default: 0

    # When the first-visit step was finished or skipped, and when the recovery
    # notice was dismissed (ADR 0058). Both are stamped by `Baudrate.Auth`,
    # never cast from params: a member who could set `onboarded_at` in a form
    # gains nothing, but one who could clear somebody else's would be deciding
    # what another account is shown.
    field :onboarded_at, :utc_datetime
    field :recovery_notice_dismissed_at, :utc_datetime

    # When this account deleted itself and became a tombstone (ADR 0072).
    # Written only by `tombstone_changeset/1`.
    field :deleted_at, :utc_datetime

    belongs_to :role, Baudrate.Setup.Role
    belongs_to :invited_by, __MODULE__

    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :terms_accepted, :boolean, virtual: true, default: false

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for new user registration: validates username, password policy, and hashes the password."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :password,
      :password_confirmation,
      :role_id,
      :terms_accepted
    ])
    |> validate_username()
    |> validate_password()
    |> assoc_constraint(:role)
    # Deliberately not cast: the invite chain is a moderation signal ("an
    # account that invited five spammers is a different case from one that
    # invited none"), and it was settable from the registration form by an
    # unauthenticated visitor. `Auth.Users.register_with_invite/1` puts it
    # there from the validated invite instead.
    |> foreign_key_constraint(:invited_by_id)
    |> hash_password()
  end

  @doc """
  Validates the registration checkbox and records what was accepted.

  Checking the box and recording it are one step on purpose. They were two
  before this existed — the box was validated and the answer thrown away — so
  editing the terms silently changed what every member had agreed to. A
  registration path that forgot the recording half would recreate exactly that,
  and both callers in `Baudrate.Auth.Users` reach it through here.
  """
  def accept_terms(changeset) do
    changeset
    |> validate_acceptance(:terms_accepted)
    |> stamp_acceptance()
  end

  # Nothing to record on a changeset that is not going to be inserted.
  defp stamp_acceptance(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp stamp_acceptance(changeset) do
    changeset
    |> put_change(:terms_accepted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> put_change(:terms_version, Baudrate.Setup.current_terms_version())
  end

  defp validate_username(changeset) do
    changeset
    |> validate_required([:username])
    |> validate_length(:username, min: 3, max: 32)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "only allows letters, numbers, and underscores"
    )
    # Case-folded: `Admin` alongside `admin` was a distinct fediverse actor
    # (impersonation) and made `get_user_by_username_ci/1` return two rows,
    # which crashed every mention of that name.
    |> unique_constraint(:username, name: :users_lower_username_index)
    |> validate_username_not_board_slug()
  end

  # Prevents a username from shadowing a board in WebFinger resolution, and
  # prevents re-registration of handles freed by deletion (anti-fraud).
  # WebFinger resolves users before boards for bare-slug queries, so a username
  # that matches a board slug (case-insensitively) would make the board
  # undiscoverable via federation.
  defp validate_username_not_board_slug(changeset) do
    validate_change(changeset, :username, fn :username, username ->
      slug = String.downcase(username)

      cond do
        Baudrate.Repo.exists?(from b in "boards", where: b.slug == ^slug) ->
          [username: "is already used by a board on this instance"]

        Baudrate.Repo.exists?(from r in "reserved_handles", where: r.handle == ^slug) ->
          [username: "has been reserved and is no longer available"]

        true ->
          []
      end
    end)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    |> validate_format(:password, ~r/[a-z]/, message: "must contain a lowercase letter")
    |> validate_format(:password, ~r/[A-Z]/, message: "must contain an uppercase letter")
    |> validate_format(:password, ~r/[0-9]/, message: "must contain a digit")
    |> validate_format(:password, ~r/[^a-zA-Z0-9]/, message: "must contain a special character")
    |> validate_confirmation(:password, message: "does not match password")
  end

  @doc """
  Validates a new password and its confirmation against the password policy
  without hashing it. Used to report problems before any expensive or
  rate-limited step (e.g. step-up re-authentication) runs.
  """
  def password_validation_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_password()
  end

  @doc "Changeset for resetting a user's password: validates and hashes the new password."
  def password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_password()
    |> hash_password()
  end

  @doc "Changeset for updating a user's avatar ID."
  def avatar_changeset(user, attrs) do
    user
    |> cast(attrs, [:avatar_id])
  end

  @doc "Changeset for updating the TOTP secret, enabled flag, and enablement timestamp."
  def totp_changeset(user, attrs) do
    user
    |> cast(attrs, [:totp_secret, :totp_enabled, :totp_enabled_at, :totp_last_used_step])
  end

  @doc "Changeset for setting user status to `\"active\"` or `\"pending\"`."
  def status_changeset(user, attrs) do
    user
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, ["active", "pending"])
    |> refuse_deleted()
  end

  @doc """
  Changeset for the account's aliases (`also_known_as`). Only
  `Baudrate.AccountMigration` calls it, with actor ids it has resolved.
  """
  def aliases_changeset(user, aliases) when is_list(aliases) do
    user
    |> change(also_known_as: aliases)
    |> validate_length(:also_known_as, max: 5)
  end

  @doc """
  Changeset for the moved state. `moved_to` is an actor id, or `nil` to remove
  the redirect. Only `Baudrate.AccountMigration` calls it.
  """
  def moved_changeset(user, moved_to, moved_at) do
    user
    |> change(moved_to: moved_to, moved_at: moved_at)
    |> validate_format(:moved_to, ~r{\Ahttps://}, message: "must be an https URI")
  end

  @doc "Changeset for banning a user: sets status to `\"banned\"` with timestamp and optional reason."
  def ban_changeset(user, attrs) do
    user
    |> cast(attrs, [:status, :banned_at, :ban_reason])
    |> validate_required([:status, :banned_at])
    |> validate_inclusion(:status, ["banned"])
    |> validate_length(:ban_reason, max: 500)
    |> refuse_deleted()
  end

  @doc "Changeset for unbanning a user: resets status to `\"active\"` and clears ban fields."
  def unban_changeset(user) do
    user
    |> cast(%{status: "active"}, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, ["active"])
    |> put_change(:banned_at, nil)
    |> put_change(:ban_reason, nil)
    |> refuse_deleted()
  end

  # A tombstone is final (ADR 0072): banning it and then unbanning it would
  # otherwise bring a deleted account back as "active".
  defp refuse_deleted(%Ecto.Changeset{data: %{status: "deleted"}} = changeset),
    do: add_error(changeset, :status, "this account has been deleted")

  defp refuse_deleted(changeset), do: changeset

  @doc "Changeset for updating a user's role assignment."
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role_id])
    |> validate_required([:role_id])
    |> assoc_constraint(:role)
  end

  @doc "Changeset for updating the user's ActivityPub RSA keypair."
  def ap_key_changeset(user, attrs) do
    user
    |> cast(attrs, [:ap_public_key, :ap_private_key_encrypted])
  end

  @max_signature_lines 8

  @doc "Changeset for updating the user's forum signature (max 500 chars, 8 lines)."
  def signature_changeset(user, attrs) do
    user
    |> cast(attrs, [:signature])
    |> validate_length(:signature, max: 500)
    |> validate_change(:signature, fn :signature, signature ->
      newline_count = signature |> String.graphemes() |> Enum.count(&(&1 == "\n"))

      if newline_count > @max_signature_lines - 1 do
        [signature: "must not exceed #{@max_signature_lines} lines"]
      else
        []
      end
    end)
  end

  @doc "Changeset for updating the user's preferred locale list."
  def locale_changeset(user, attrs) do
    known = Gettext.known_locales(BaudrateWeb.Gettext)

    user
    |> cast(attrs, [:preferred_locales])
    |> validate_change(:preferred_locales, fn :preferred_locales, locales ->
      invalid = Enum.reject(locales, &(&1 in known))

      if invalid == [] do
        []
      else
        [preferred_locales: "contains unknown locales: #{Enum.join(invalid, ", ")}"]
      end
    end)
  end

  @doc "Changeset for updating the user's bio (max 500 chars, plaintext)."
  def bio_changeset(user, attrs) do
    user
    |> cast(attrs, [:bio])
    |> validate_length(:bio, max: 500)
  end

  @doc "Changeset for updating the user's display name (max 64 chars, sanitized)."
  def display_name_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name])
    |> update_change(:display_name, &sanitize_display_name/1)
    |> validate_length(:display_name, max: 64)
  end

  defp sanitize_display_name(nil), do: nil

  defp sanitize_display_name(name) when is_binary(name) do
    result =
      name
      |> Baudrate.Sanitizer.Native.strip_tags()
      |> Baudrate.Sanitizer.Native.decode_html_entities()
      # Remove control characters
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
      # Remove Unicode bidi override characters
      |> String.replace(~r/[\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u, "")
      |> String.trim()
      # Collapse consecutive whitespace to single space
      |> String.replace(~r/\s+/, " ")
      |> String.slice(0, 64)

    if result == "", do: nil, else: result
  end

  @doc "Changeset for updating DM access preference (`\"anyone\"`, `\"followers\"`, or `\"nobody\"`)."
  def dm_access_changeset(user, attrs) do
    user
    |> cast(attrs, [:dm_access])
    |> validate_required([:dm_access])
    |> validate_inclusion(:dm_access, ["anyone", "followers", "nobody"])
  end

  @doc """
  Turns a self-deleted account into a tombstone (ADR 0072).

  The row is never deleted — other members' comments, DMs, reports and the
  invite tree point at it — so this clears everything personal and keeps
  only what identifies the row and what is a record rather than a profile:
  the username (which stays reserved), the role, `is_bot`, the ban and
  terms fields, `moved_to`/`moved_at`, `invited_by_id` (the ban-chain
  lineage) and the signing keys, which `Baudrate.AccountDeletion` clears
  once the account's last deliveries are out.

  The password becomes a bcrypt hash of random bytes: the column is NOT
  NULL, and a non-bcrypt value would make `Bcrypt.verify_pass/2` error.
  Nothing here is cast from params.
  """
  def tombstone_changeset(user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    change(user,
      status: "deleted",
      deleted_at: now,
      display_name: nil,
      bio: nil,
      signature: nil,
      profile_fields: [],
      also_known_as: [],
      avatar_id: nil,
      hashed_password: Bcrypt.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(32))),
      totp_secret: nil,
      totp_enabled: false,
      totp_enabled_at: nil,
      totp_last_used_step: nil,
      preferred_locales: [],
      time_zone: nil,
      notification_preferences: %{},
      dm_access: "nobody",
      last_active_on: nil,
      onboarded_at: nil,
      recovery_notice_dismissed_at: nil,
      muted_keywords: [],
      manually_approves_followers: false,
      discoverable: false
    )
  end

  @max_muted_keywords 50

  @doc "The most muted words one member may keep."
  def max_muted_keywords, do: @max_muted_keywords

  @doc """
  Changeset for the member's muted words (ADR 0073): a list of
  `%{"kind" => "word" | "substring", "pattern" => …}`, each pattern
  normalized the way the admin filters normalize theirs and judged by the
  same rule (`ContentFilter.pattern_error/2`), at most #{@max_muted_keywords}.
  Nothing else casts `:muted_keywords`.
  """
  def muted_keywords_changeset(user, keywords) when is_list(keywords) do
    alias Baudrate.Moderation.ContentFilter

    normalized =
      Enum.map(keywords, fn entry ->
        kind = entry["kind"] || entry[:kind]

        pattern =
          ContentFilter.normalize_text(to_string(entry["pattern"] || entry[:pattern] || ""))

        %{"kind" => kind, "pattern" => pattern}
      end)
      |> Enum.uniq()

    user
    |> change(muted_keywords: normalized)
    |> validate_length(:muted_keywords, max: @max_muted_keywords)
    |> validate_change(:muted_keywords, fn :muted_keywords, list ->
      Enum.flat_map(list, fn %{"kind" => kind, "pattern" => pattern} ->
        cond do
          kind not in ["word", "substring"] -> [muted_keywords: "has an unknown kind"]
          pattern == "" -> [muted_keywords: "has an empty entry"]
          String.length(pattern) > 200 -> [muted_keywords: "has an entry that is too long"]
          message = ContentFilter.pattern_error(kind, pattern) -> [muted_keywords: message]
          true -> []
        end
      end)
    end)
  end

  @doc """
  Changeset for the two privacy switches (ADR 0073): approving followers
  manually, and being discoverable. Neither is cast anywhere else.
  """
  def privacy_changeset(user, attrs) do
    user
    |> cast(attrs, [:manually_approves_followers, :discoverable])
    |> validate_required([:manually_approves_followers, :discoverable])
  end

  @doc """
  Changeset for the member's own time zone: an IANA name the tz database
  knows (`Baudrate.Timezone.identifiers/0`), or `nil`/`""` for the site's.
  No other changeset casts `:time_zone`.
  """
  def time_zone_changeset(user, attrs) do
    user
    |> cast(attrs, [:time_zone], empty_values: [""])
    |> validate_inclusion(:time_zone, Baudrate.Timezone.identifiers())
  end

  @doc """
  Changeset for updating notification preferences.

  Accepts a map of `%{"type" => %{"in_app" => boolean}}`. Only types from
  `Baudrate.Notification.Notification.configurable_types/0` and the push-only
  `push_only_types/0` (`"direct_message"`) are allowed; unknown keys and
  account security notice types are rejected.
  """
  def notification_preferences_changeset(user, attrs) do
    user
    |> cast(attrs, [:notification_preferences])
    |> validate_change(:notification_preferences, fn :notification_preferences, prefs ->
      allowed =
        Baudrate.Notification.Notification.configurable_types() ++
          Baudrate.Notification.Notification.push_only_types()

      invalid_types = Map.keys(prefs) -- allowed

      if invalid_types == [] do
        []
      else
        [notification_preferences: "contains unknown types: #{Enum.join(invalid_types, ", ")}"]
      end
    end)
  end

  @max_profile_fields 4
  @max_profile_field_name_length 255
  @max_profile_field_value_length 2048

  @doc """
  Changeset for updating a user's profile fields (custom metadata key-value pairs).

  Accepts a list of up to #{@max_profile_fields} maps, each with `"name"` (max
  #{@max_profile_field_name_length} chars) and `"value"` (max
  #{@max_profile_field_value_length} chars) string keys. Empty-name entries are
  filtered out before saving via `Baudrate.Auth.Profiles.update_profile_fields/2`.
  Published as `attachment` entries with type `PropertyValue` on the AP actor.
  """
  def profile_fields_changeset(user, attrs) do
    user
    |> cast(attrs, [:profile_fields])
    |> validate_change(:profile_fields, fn :profile_fields, fields ->
      cond do
        length(fields) > @max_profile_fields ->
          [profile_fields: "cannot have more than #{@max_profile_fields} fields"]

        not Enum.all?(fields, &valid_profile_field?/1) ->
          [profile_fields: "contains invalid fields"]

        true ->
          []
      end
    end)
  end

  defp valid_profile_field?(%{"name" => name, "value" => value})
       when is_binary(name) and is_binary(value) do
    String.length(name) <= @max_profile_field_name_length and
      String.length(value) <= @max_profile_field_value_length
  end

  defp valid_profile_field?(_), do: false

  @doc """
  Changeset for creating a bot user account.

  Sets `is_bot: true`, `dm_access: "nobody"`, `status: "active"`, and a
  locked password. The bot account cannot be logged into by humans; the
  `authenticate_by_password/2` function rejects bot accounts.
  """
  def bot_registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password, :password_confirmation, :role_id])
    |> validate_username()
    |> validate_password()
    |> assoc_constraint(:role)
    |> hash_password()
    |> put_change(:is_bot, true)
    |> put_change(:dm_access, "nobody")
    |> put_change(:status, "active")
  end

  defp hash_password(changeset) do
    if changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(get_change(changeset, :password)))
      |> delete_change(:password)
      |> delete_change(:password_confirmation)
    else
      changeset
    end
  end
end
