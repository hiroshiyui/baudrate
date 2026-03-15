defmodule Baudrate.Auth do
  @moduledoc """
  Facade for the Auth context. Delegates to specialized sub-modules:

  - `Passwords` (Authentication and reset)
  - `Sessions` (Session and refresh token lifecycle)
  - `SecondFactor` (TOTP and recovery codes)
  - `Invites` (Invitation system)
  - `Moderation` (Banning, blocking, and muting)
  - `Users` (Registration, search, and retrieval)
  - `Profiles` (User preferences and profile updates)
  """

  alias Baudrate.Auth.{
    Invites,
    Moderation,
    Passwords,
    Profiles,
    SecondFactor,
    Sessions,
    Users
  }

  # --- Passwords & Core Auth ---
  defdelegate authenticate_by_password(username, password), to: Passwords
  defdelegate verify_password(user, password), to: Passwords

  defdelegate reset_password_with_recovery_code(
                username,
                recovery_code,
                new_password,
                new_password_confirmation
              ),
              to: Passwords

  # --- Users ---
  defdelegate get_user(id), to: Users
  defdelegate get_user_by_username(username), to: Users
  defdelegate get_user_by_username_ci(username), to: Users
  defdelegate register_user(attrs), to: Users
  defdelegate approve_user(user), to: Users
  defdelegate list_pending_users, to: Users
  defdelegate user_active?(user), to: Users
  defdelegate can_create_content?(user), to: Users
  defdelegate can_upload_avatar?(user), to: Users
  defdelegate search_users(term, opts \\ []), to: Users
  defdelegate list_users(opts \\ []), to: Users
  defdelegate paginate_users(opts \\ []), to: Users
  defdelegate count_users_by_status, to: Users
  defdelegate update_user_role(user, role_id, admin_id), to: Users

  # --- Sessions & Throttling ---
  defdelegate generate_token, to: Sessions
  defdelegate hash_token(raw_token), to: Sessions
  defdelegate create_user_session(user_id, opts \\ []), to: Sessions
  defdelegate get_user_by_session_token(raw_token), to: Sessions
  defdelegate refresh_user_session(raw_refresh_token), to: Sessions
  defdelegate delete_session_by_token(raw_token), to: Sessions
  defdelegate delete_all_sessions_for_user(user_id), to: Sessions
  defdelegate purge_expired_sessions, to: Sessions
  defdelegate record_login_attempt(username, ip_address, success), to: Sessions
  defdelegate check_login_throttle(username), to: Sessions
  defdelegate paginate_login_attempts(opts \\ []), to: Sessions
  defdelegate purge_old_login_attempts, to: Sessions

  # --- Second Factor ---
  defdelegate totp_policy(role_name), to: SecondFactor
  defdelegate login_next_step(user), to: SecondFactor
  defdelegate generate_totp_secret, to: SecondFactor
  defdelegate totp_uri(secret, username, issuer \\ "Baudrate"), to: SecondFactor
  defdelegate totp_qr_data_uri(uri), to: SecondFactor
  defdelegate valid_totp?(secret, code, opts \\ []), to: SecondFactor
  defdelegate enable_totp(user, secret), to: SecondFactor
  defdelegate decrypt_totp_secret(user), to: SecondFactor
  defdelegate disable_totp(user), to: SecondFactor
  defdelegate generate_recovery_codes(user), to: SecondFactor
  defdelegate verify_recovery_code(user, code), to: SecondFactor

  # --- Invites ---
  defdelegate can_generate_invite?(user), to: Invites
  defdelegate invite_quota_remaining(user), to: Invites
  defdelegate invite_quota_limit, to: Invites
  defdelegate list_user_invite_codes(user), to: Invites
  defdelegate generate_invite_code(user, opts \\ []), to: Invites
  defdelegate admin_generate_invite_code_for_user(admin, target_user, opts \\ []), to: Invites
  defdelegate get_invite_code(id), to: Invites
  defdelegate validate_invite_code(code), to: Invites
  defdelegate use_invite_code(invite, user_id), to: Invites
  defdelegate list_all_invite_codes, to: Invites
  defdelegate list_all_invite_codes(opts), to: Invites
  defdelegate revoke_invite_code(invite), to: Invites
  defdelegate revoke_invite_codes_for_user(user_id), to: Invites

  # --- Moderation ---
  defdelegate ban_user(user, admin_id, reason \\ nil), to: Moderation
  defdelegate unban_user(user), to: Moderation
  defdelegate block_user(user, target), to: Moderation
  defdelegate block_remote_actor(user, ap_id), to: Moderation
  defdelegate unblock_user(user, target), to: Moderation
  defdelegate unblock_remote_actor(user, ap_id), to: Moderation
  defdelegate blocked?(user, target), to: Moderation
  defdelegate user_blocked_by?(user_id, blocker_id), to: Moderation
  defdelegate list_blocks(user), to: Moderation
  defdelegate blocked_user_ids(user), to: Moderation
  defdelegate blocked_actor_ap_ids(user), to: Moderation
  defdelegate mute_user(user, target), to: Moderation
  defdelegate mute_remote_actor(user, ap_id), to: Moderation
  defdelegate unmute_user(user, target), to: Moderation
  defdelegate unmute_remote_actor(user, ap_id), to: Moderation
  defdelegate muted?(user, target), to: Moderation
  defdelegate list_mutes(user), to: Moderation
  defdelegate muted_user_ids(user), to: Moderation
  defdelegate muted_actor_ap_ids(user), to: Moderation
  defdelegate hidden_ids(user), to: Moderation

  # --- Profiles & Preferences ---
  defdelegate update_preferred_locales(user, locales), to: Profiles
  defdelegate update_avatar(user, avatar_id), to: Profiles
  defdelegate remove_avatar(user), to: Profiles
  defdelegate update_signature(user, signature), to: Profiles
  defdelegate update_display_name(user, display_name), to: Profiles
  defdelegate update_bio(user, bio), to: Profiles
  defdelegate update_dm_access(user, value), to: Profiles
  defdelegate update_notification_preferences(user, prefs), to: Profiles
end
