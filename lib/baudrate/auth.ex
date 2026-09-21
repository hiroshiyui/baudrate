defmodule Baudrate.Auth do
  @moduledoc """
  Facade for the Auth context. Delegates to specialized sub-modules:

  - `Passwords` (Authentication and reset)
  - `Sessions` (Session and refresh token lifecycle)
  - `SecondFactor` (TOTP and recovery codes)
  - `Invites` (Invitation system)
  - `Moderation` (Banning, blocking, and muting)
  - `Sanctions` (Warnings, silences and suspensions, and the interaction gate)
  - `Users` (Registration, search, and retrieval)
  - `Profiles` (User preferences and profile updates)
  """

  alias Baudrate.Auth.{
    Invites,
    Moderation,
    Passwords,
    Profiles,
    Recovery,
    Sanctions,
    SecondFactor,
    Sessions,
    Users,
    WebAuthn
  }

  # --- Passwords & Core Auth ---
  defdelegate authenticate_by_password(username, password), to: Passwords
  defdelegate verify_password(user, password), to: Passwords
  defdelegate password_change_changeset(user, attrs), to: Passwords
  defdelegate change_password(user, attrs, keep_session_id), to: Passwords

  defdelegate verify_reauthentication(user, password, code, ip_address, purpose),
    to: Baudrate.Auth.Reauthentication,
    as: :verify

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
  defdelegate accept_current_terms(user), to: Users
  defdelegate terms_pending?(user), to: Users
  defdelegate approve_user(user), to: Users
  defdelegate onboarded?(user), to: Users
  defdelegate mark_onboarded(user), to: Users
  defdelegate dismiss_recovery_notice(user), to: Users
  defdelegate list_pending_users, to: Users
  defdelegate list_invitees(user_id, limit \\ 20), to: Users
  defdelegate user_active?(user), to: Users
  defdelegate can_create_content?(user), to: Users
  defdelegate can_upload_avatar?(user), to: Users
  defdelegate search_users(term, opts \\ []), to: Users
  defdelegate search_users_page(term, opts \\ []), to: Users
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
  defdelegate delete_other_sessions_for_user(user_id, keep_session_id), to: Sessions
  defdelegate session_id_by_token(raw_token), to: Sessions
  defdelegate live_socket_id(session_id), to: Sessions
  defdelegate sign_out_other_sessions(user, keep_session_id), to: Sessions
  defdelegate purge_expired_sessions, to: Sessions

  defdelegate record_login_attempt(username, ip_address, success, factor \\ "password"),
    to: Sessions

  defdelegate check_login_throttle(username), to: Sessions
  defdelegate paginate_login_attempts(opts \\ []), to: Sessions
  defdelegate purge_old_login_attempts, to: Sessions

  # --- Second Factor ---
  defdelegate totp_policy(role_name), to: SecondFactor
  defdelegate login_next_step(user), to: SecondFactor
  defdelegate generate_totp_secret, to: SecondFactor
  defdelegate totp_uri(secret, username, issuer \\ "Baudrate"), to: SecondFactor
  defdelegate totp_qr_data_uri(uri), to: SecondFactor
  defdelegate match_totp_step(secret, code), to: SecondFactor
  defdelegate verify_totp_code(user, code, opts \\ []), to: SecondFactor
  defdelegate record_login_totp_failure(user, ip_address), to: SecondFactor
  defdelegate enable_totp(user, secret, opts \\ []), to: SecondFactor
  defdelegate decrypt_totp_secret(user), to: SecondFactor
  defdelegate disable_totp(user), to: SecondFactor
  defdelegate totp_enabled_for_at_least?(user, days), to: SecondFactor
  defdelegate generate_recovery_codes(user), to: SecondFactor
  defdelegate regenerate_recovery_codes(user), to: SecondFactor
  defdelegate verify_recovery_code(user, code), to: SecondFactor

  # --- Account recovery (ADR 0058) ---
  defdelegate list_recovery_contacts(user), to: Recovery, as: :list_contacts
  defdelegate add_recovery_contact(user, attrs), to: Recovery, as: :add_contact
  defdelegate update_recovery_contact(user, contact_id, attrs), to: Recovery, as: :update_contact
  defdelegate remove_recovery_contact(user, contact_id), to: Recovery, as: :remove_contact

  defdelegate set_recovery_contact_verification(admin, contact_id, status),
    to: Recovery,
    as: :set_verification

  defdelegate recovery_arranged?(user), to: Recovery, as: :arranged?
  defdelegate verified_recovery_contact?(user), to: Recovery, as: :verified_contact?
  defdelegate unused_recovery_code_count(user), to: Recovery, as: :unused_code_count
  defdelegate max_recovery_contacts, to: Recovery, as: :max_contacts
  defdelegate issue_account_reset(admin, user, contact_id, opts \\ []), to: Recovery, as: :issue
  defdelegate can_issue_account_reset?(admin, user), to: Recovery, as: :can_issue?
  defdelegate revoke_account_reset(admin, user), to: Recovery, as: :revoke
  defdelegate live_account_reset(user), to: Recovery, as: :live_reset

  defdelegate redeem_account_reset(token, password, password_confirmation),
    to: Recovery,
    as: :redeem

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
  defdelegate ban_user(user, actor, reason \\ nil), to: Moderation
  defdelegate unban_user(user, actor), to: Moderation
  defdelegate block_user(user, target), to: Moderation
  defdelegate block_remote_actor(user, ap_id), to: Moderation
  defdelegate unblock_user(user, target), to: Moderation
  defdelegate unblock_remote_actor(user, ap_id), to: Moderation
  defdelegate blocked?(user, target), to: Moderation
  defdelegate user_blocked_by?(user_id, blocker_id), to: Moderation
  defdelegate blocked_between?(user_id, other_id), to: Moderation
  defdelegate remote_actor_blocked_by?(remote_actor_id, user_id), to: Moderation
  defdelegate blocked_with_author?(user_id, content), to: Moderation
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

  # --- Sanctions (ADR 0029) ---
  #
  # `ensure_can_interact/1` is the one gate every context function calls
  # before it lets an account create content or interact. It covers moved,
  # silenced, suspended and banned accounts together, so a new posting path
  # cannot enforce one rule and forget the others.
  defdelegate ensure_can_interact(user, opts \\ []), to: Sanctions
  defdelegate can_interact?(user, opts \\ []), to: Sanctions
  defdelegate active_sanctions(user), to: Sanctions
  defdelegate active_sanction(user, kind), to: Sanctions
  defdelegate silenced?(user), to: Sanctions
  defdelegate suspended?(user), to: Sanctions
  defdelegate list_sanctions(user), to: Sanctions
  defdelegate issue_sanction(actor, target, kind, opts \\ []), to: Sanctions, as: :issue
  defdelegate lift_sanction(actor, target, kind, opts \\ []), to: Sanctions, as: :lift
  defdelegate authorize_sanction(actor, target, kind), to: Sanctions, as: :authorize
  defdelegate max_sanction_expiry(actor), to: Sanctions, as: :max_expiry
  defdelegate notify_ended_sanctions, to: Sanctions

  defdelegate reject_pending_user(actor, target, reason \\ nil),
    to: Sanctions,
    as: :reject_pending

  # --- Profiles & Preferences ---
  defdelegate update_preferred_locales(user, locales), to: Profiles
  defdelegate update_avatar(user, avatar_id), to: Profiles
  defdelegate remove_avatar(user), to: Profiles
  defdelegate update_signature(user, signature), to: Profiles
  defdelegate update_display_name(user, display_name), to: Profiles
  defdelegate update_bio(user, bio), to: Profiles
  defdelegate update_dm_access(user, value), to: Profiles
  defdelegate update_notification_preferences(user, prefs), to: Profiles
  defdelegate update_profile_fields(user, fields), to: Profiles

  # --- WebAuthn ---
  defdelegate list_webauthn_credentials(user), to: WebAuthn
  defdelegate webauthn_enabled?(user), to: WebAuthn
  defdelegate create_webauthn_credential(user, attrs), to: WebAuthn
  defdelegate delete_webauthn_credential(user, id), to: WebAuthn
  defdelegate begin_registration(user), to: WebAuthn

  defdelegate finish_registration(user, attestation_object, client_data_json, challenge),
    to: WebAuthn

  defdelegate begin_authentication(user), to: WebAuthn

  defdelegate finish_authentication(
                user,
                credential_id,
                authenticator_data,
                client_data_json,
                signature,
                challenge
              ),
              to: WebAuthn
end
