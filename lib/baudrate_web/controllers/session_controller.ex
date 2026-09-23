defmodule BaudrateWeb.SessionController do
  @moduledoc """
  Handles session lifecycle via POST endpoints, called by LiveView forms
  using the `phx-trigger-action` pattern.

  ## Authentication Flow

      LoginLive (LiveView)
          │ validates credentials in the LiveProcess
          │ signs a short-lived Phoenix.Token containing user_id
          ▼
      POST /auth/session → create/2
          │ verifies Phoenix.Token (max_age: 60s)
          │ calls Auth.login_next_step/1
          ├─ :totp_verify  → redirect to /totp/verify
          ├─ :totp_setup   → store secret in session, redirect to /totp/setup
          └─ :authenticated → establish_session/2
          │
      POST /auth/totp-verify → totp_verify/2
      POST /auth/totp-enable → totp_enable/2
          │ verify TOTP code
          ▼
      establish_session/2
          │ creates server-side session (Auth.create_user_session/2)
          │ stores session_token + refresh_token in cookie
          │ clears intermediate session keys (user_id, totp_*)
          ▼
      redirect to /

  ## TOTP Lockout

  After 5 failed TOTP attempts (`@max_totp_attempts`), the session is dropped
  and the user must re-authenticate from the login page. Attempt count is
  tracked in the cookie session under `:totp_attempts`.

  That counter resets with every new login, so it is not the real bound.
  Each failed code is also recorded against the account
  (`Auth.record_login_totp_failure/2`, ADR 0024), `totp_verify/2` honours
  the per-account login throttle, and repeated failures send the owner a
  `totp_login_failed` security notice. Codes are consumed on use
  (`Auth.verify_totp_code/3`): the current or previous 30-second code is
  accepted, once.

  ## Admin Sudo Mode

  `admin_totp_verify/2` handles TOTP re-verification for admin sudo mode.
  After 5 failed attempts (`admin_totp_attempts`), the admin is locked out
  of admin pages but the session is NOT dropped (they remain logged in).
  On success, `admin_totp_verified_at` (Unix timestamp) is set in the
  cookie session, granting admin access for 10 minutes.

  `admin_webauthn_verify/2` is the WebAuthn equivalent for admins who have
  enrolled security keys. On success it sets the same `admin_totp_verified_at`
  key so the existing `:require_admin_totp` hook needs no changes.

  ## WebAuthn Registration

  `webauthn_register/2` handles security key enrollment from `/profile/security`. The
  LiveView begins the ceremony, the browser completes
  `navigator.credentials.create()`, and the attestation response is POSTed
  here for verification by `wax_` before persistence.

  ## Security Logging

  All auth events are logged with structured prefixes (`auth.login_success`,
  `auth.totp_lockout`, etc.) including `user_id` and `ip` for audit trails.
  """

  use BaudrateWeb, :controller

  require Logger

  alias Baudrate.Auth
  alias BaudrateWeb.RateLimits

  @max_totp_attempts 5

  @doc "Verifies the short-lived Phoenix.Token from LoginLive and routes to the next auth step."
  def create(conn, %{"token" => token} = params) do
    case Phoenix.Token.verify(conn, "user_auth", token, max_age: 60) do
      {:ok, user_id} ->
        user = Auth.get_user(user_id)

        # The token is minted the moment the password verifies, so a
        # suspension issued in between must still be caught here (ADR 0029).
        if user && user.status not in ["banned", "deleted"] && not Auth.suspended?(user) do
          Logger.info(
            "auth.login_success: user_id=#{user.id} username=#{user.username} ip=#{remote_ip(conn)}"
          )

          conn =
            conn
            |> configure_session(renew: true)
            |> put_session(:user_id, user.id)

          case Auth.login_next_step(user) do
            :totp_verify ->
              conn
              |> delete_session(:totp_attempts)
              |> redirect(to: "/totp/verify")

            :totp_setup ->
              secret = Auth.generate_totp_secret()

              conn
              |> put_session(:totp_setup_secret, secret)
              |> delete_session(:totp_attempts)
              |> redirect(to: "/totp/setup")

            :authenticated ->
              establish_session(conn, user, login_landing(params))
          end
        else
          conn
          |> put_flash(:error, gettext("Invalid session."))
          |> redirect(to: "/login")
        end

      {:error, _reason} ->
        Logger.warning("auth.invalid_token: ip=#{remote_ip(conn)}")

        conn
        |> put_flash(:error, gettext("Invalid or expired token."))
        |> redirect(to: "/login")
    end
  end

  @doc "Verifies a TOTP code during login and establishes the session on success."
  def totp_verify(conn, %{"code" => code}) do
    user_id = get_session(conn, :user_id)
    user = user_id && Auth.get_user(user_id)
    attempts = get_session(conn, :totp_attempts) || 0
    secret = user && Auth.decrypt_totp_secret(user)

    cond do
      is_nil(user) ->
        conn
        |> put_flash(:error, gettext("Session expired. Please log in again."))
        |> redirect(to: "/login")

      is_nil(secret) ->
        Logger.error("auth.totp_decrypt_error: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> put_flash(
          :error,
          gettext("TOTP configuration error. Please contact an administrator.")
        )
        |> configure_session(drop: true)
        |> redirect(to: "/login")

      attempts >= @max_totp_attempts ->
        Logger.warning("auth.totp_lockout: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> configure_session(drop: true)
        |> put_flash(:error, gettext("Too many failed attempts. Please log in again."))
        |> redirect(to: "/login")

      seconds = login_throttle_seconds(user) ->
        Logger.warning("auth.totp_verify_throttled: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> put_flash(
          :error,
          gettext("Account temporarily locked. Try again in %{seconds} seconds.",
            seconds: seconds
          )
        )
        |> redirect(to: "/totp/verify")

      Auth.verify_totp_code(user, code) ->
        Logger.info("auth.totp_verify_success: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> delete_session(:totp_attempts)
        |> establish_session(user)

      true ->
        Logger.warning(
          "auth.totp_verify_failure: user_id=#{user.id} attempt=#{attempts + 1} ip=#{remote_ip(conn)}"
        )

        Auth.record_login_totp_failure(user, remote_ip(conn))

        conn
        |> put_session(:totp_attempts, attempts + 1)
        |> put_flash(:error, gettext("Invalid verification code. Please try again."))
        |> redirect(to: "/totp/verify")
    end
  end

  @doc "Verifies a TOTP code during first-time setup, enables TOTP, and generates recovery codes."
  def totp_enable(conn, %{"code" => code}) do
    user_id = get_session(conn, :user_id)
    user = user_id && Auth.get_user(user_id)
    secret = get_session(conn, :totp_setup_secret)
    attempts = get_session(conn, :totp_attempts) || 0

    cond do
      is_nil(user) || is_nil(secret) ->
        conn
        |> put_flash(:error, gettext("Session expired. Please log in again."))
        |> redirect(to: "/login")

      attempts >= @max_totp_attempts ->
        Logger.warning("auth.totp_setup_lockout: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> configure_session(drop: true)
        |> put_flash(:error, gettext("Too many failed attempts. Please log in again."))
        |> redirect(to: "/login")

      step = enrolment_code_step(secret, code) ->
        case Auth.enable_totp(user, secret, used_step: step) do
          {:ok, updated_user} ->
            Logger.info("auth.totp_enabled: user_id=#{user.id} ip=#{remote_ip(conn)}")

            conn
            |> delete_session(:totp_setup_secret)
            |> delete_session(:totp_attempts)
            |> put_flash(:info, gettext("Two-factor authentication enabled successfully."))
            |> establish_session(updated_user, "/profile/security")

          {:error, _changeset} ->
            Logger.error("auth.totp_enable_failed: user_id=#{user.id} ip=#{remote_ip(conn)}")

            conn
            |> put_flash(:error, gettext("Failed to enable TOTP. Please try again."))
            |> redirect(to: "/totp/setup")
        end

      true ->
        Logger.warning(
          "auth.totp_setup_failure: user_id=#{user.id} attempt=#{attempts + 1} ip=#{remote_ip(conn)}"
        )

        conn
        |> put_session(:totp_attempts, attempts + 1)
        |> put_flash(:error, gettext("Invalid verification code. Please try again."))
        |> redirect(to: "/totp/setup")
    end
  end

  @doc "Handles TOTP reset: invalidates all sessions, disables TOTP, and redirects to setup."
  def totp_reset(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "totp_reset", token, max_age: 60) do
      {:ok, %{user_id: user_id, mode: mode}} ->
        user = Auth.get_user(user_id)

        if user do
          Logger.info(
            "auth.totp_reset_start: user_id=#{user.id} mode=#{mode} ip=#{remote_ip(conn)}"
          )

          # Delete all existing sessions for this user
          Auth.delete_all_sessions_for_user(user.id)

          # Disable TOTP if resetting (not enabling for first time)
          if mode == :reset do
            Auth.disable_totp(user)
          end

          # Generate new TOTP secret and put in session for /totp/setup
          secret = Auth.generate_totp_secret()

          conn
          |> configure_session(renew: true)
          |> put_session(:user_id, user.id)
          |> put_session(:totp_setup_secret, secret)
          |> delete_session(:totp_attempts)
          |> redirect(to: "/totp/setup")
        else
          conn
          |> put_flash(:error, gettext("Invalid session."))
          |> redirect(to: "/login")
        end

      {:error, _reason} ->
        Logger.warning("auth.totp_reset_invalid_token: ip=#{remote_ip(conn)}")

        conn
        |> put_flash(:error, gettext("Invalid or expired token."))
        |> redirect(to: "/profile/security")
    end
  end

  @doc "Verifies a one-time recovery code and establishes the session on success."
  def recovery_verify(conn, %{"code" => code}) do
    user_id = get_session(conn, :user_id)
    user = user_id && Auth.get_user(user_id)
    attempts = get_session(conn, :totp_attempts) || 0

    cond do
      is_nil(user) ->
        conn
        |> put_flash(:error, gettext("Session expired. Please log in again."))
        |> redirect(to: "/login")

      attempts >= @max_totp_attempts ->
        Logger.warning("auth.recovery_lockout: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> configure_session(drop: true)
        |> put_flash(:error, gettext("Too many failed attempts. Please log in again."))
        |> redirect(to: "/login")

      Auth.verify_recovery_code(user, code) == :ok ->
        Logger.info("auth.recovery_code_used: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> delete_session(:totp_attempts)
        |> establish_session(user)

      true ->
        Logger.warning(
          "auth.recovery_verify_failure: user_id=#{user.id} attempt=#{attempts + 1} ip=#{remote_ip(conn)}"
        )

        conn
        |> put_session(:totp_attempts, attempts + 1)
        |> put_flash(:error, gettext("Invalid recovery code. Please try again."))
        |> redirect(to: "/totp/recovery")
    end
  end

  @doc """
  Verifies an admin's TOTP code for sudo-mode re-authentication.

  Called via `phx-trigger-action` from `AdminTotpVerifyLive`. On success,
  sets `admin_totp_verified_at` (Unix timestamp) in the cookie session and
  redirects to the validated `return_to` path. On failure, increments
  `admin_totp_attempts` and redirects back to `/admin/verify`. Locks out
  after 5 attempts (redirects to `/` without dropping the session).

  The lockout is enforced by `RateLimits.check_admin_sudo/1`, a per-user
  bucket (5 attempts / 15 min) that is hit on every attempt before the code
  is checked. The cookie counter alone was resettable — it was deleted on
  lockout, so the next POST started again at zero — which left the 6-digit
  code brute-forceable by anyone holding a hijacked admin session, bounded
  only by the per-IP limit.
  """
  def admin_totp_verify(conn, %{"code" => code} = params) do
    session_token = get_session(conn, :session_token)
    return_to = sanitize_admin_return_to(params["return_to"])

    case session_token && Auth.get_user_by_session_token(session_token) do
      {:ok, user} when user.role.name == "admin" ->
        attempts = get_session(conn, :admin_totp_attempts) || 0
        sudo_locked? = RateLimits.check_admin_sudo(user.id) != :ok
        secret = Auth.decrypt_totp_secret(user)

        cond do
          is_nil(secret) ->
            Logger.error(
              "auth.admin_totp_decrypt_error: user_id=#{user.id} ip=#{remote_ip(conn)}"
            )

            conn
            |> put_flash(
              :error,
              gettext("TOTP configuration error. Please contact an administrator.")
            )
            |> redirect(to: "/profile/security")

          sudo_locked? or attempts >= @max_totp_attempts ->
            Logger.warning("auth.admin_totp_lockout: user_id=#{user.id} ip=#{remote_ip(conn)}")

            conn
            |> delete_session(:admin_totp_attempts)
            |> put_flash(:error, gettext("Too many failed attempts. Please try again later."))
            |> redirect(to: "/")

          Auth.verify_totp_code(user, code) ->
            Logger.info(
              "auth.admin_totp_verify_success: user_id=#{user.id} ip=#{remote_ip(conn)}"
            )

            conn
            |> delete_session(:admin_totp_attempts)
            |> put_session(:admin_totp_verified_at, System.system_time(:second))
            |> redirect(to: return_to)

          true ->
            Logger.warning(
              "auth.admin_totp_verify_failure: user_id=#{user.id} attempt=#{attempts + 1} ip=#{remote_ip(conn)}"
            )

            conn
            |> put_session(:admin_totp_attempts, attempts + 1)
            |> put_flash(:error, gettext("Invalid verification code. Please try again."))
            |> redirect(to: "/admin/verify?return_to=#{URI.encode_www_form(return_to)}")
        end

      {:ok, _non_admin} ->
        conn
        |> put_flash(:error, gettext("Access denied."))
        |> redirect(to: "/")

      _ ->
        conn
        |> put_flash(:error, gettext("Session expired. Please log in again."))
        |> redirect(to: "/login")
    end
  end

  @doc """
  Registers a WebAuthn security key for the currently authenticated user.

  Called via form POST from `ProfileSecurityLive` after the browser completes the
  `navigator.credentials.create()` ceremony. Verifies the attestation via
  `Auth.finish_registration/4`, persists the credential, and redirects to
  `/profile/security` with a flash message.
  """
  def webauthn_register(conn, params) do
    %{
      "attestation_object" => att_obj_b64,
      "client_data_json" => cdj_b64,
      "challenge_token" => token,
      "label" => label
    } = params

    session_token = get_session(conn, :session_token)

    case session_token && Auth.get_user_by_session_token(session_token) do
      {:ok, user} ->
        with {:ok, challenge} <-
               Baudrate.Auth.WebAuthnChallenges.pop(token, user.id, :attestation),
             {:ok, credential_attrs} <-
               Auth.finish_registration(user, att_obj_b64, cdj_b64, challenge),
             {:ok, _credential} <-
               Auth.create_webauthn_credential(user, Map.put(credential_attrs, :label, label)) do
          Logger.info("auth.webauthn_register_success: user_id=#{user.id} ip=#{remote_ip(conn)}")

          conn
          |> put_flash(:info, gettext("Security key registered successfully."))
          |> redirect(to: "/profile/security")
        else
          error ->
            Logger.warning(
              "auth.webauthn_register_failed: user_id=#{user.id} ip=#{remote_ip(conn)} error=#{inspect(error)}"
            )

            conn
            |> put_flash(:error, gettext("Security key registration failed. Please try again."))
            |> redirect(to: "/profile/security")
        end

      _ ->
        conn
        |> put_flash(:error, gettext("Session expired. Please log in again."))
        |> redirect(to: "/login")
    end
  end

  @doc """
  Verifies a WebAuthn assertion for admin sudo-mode re-authentication.

  Mirrors `admin_totp_verify/2` in structure. On success, sets
  `admin_totp_verified_at` (Unix timestamp) in the cookie session and redirects
  to the validated `return_to` path. On failure, increments
  `admin_webauthn_attempts` and redirects back to `/admin/verify`. Locks out
  after 5 failed attempts without dropping the session.
  """
  def admin_webauthn_verify(conn, params) do
    %{
      "authenticator_data" => ad_b64,
      "client_data_json" => cdj_b64,
      "signature" => sig_b64,
      "credential_id" => cid_b64,
      "challenge_token" => token,
      "return_to" => return_to
    } = params

    return_to = sanitize_admin_return_to(return_to)
    session_token = get_session(conn, :session_token)

    case session_token && Auth.get_user_by_session_token(session_token) do
      {:ok, user} when user.role.name == "admin" ->
        attempts = get_session(conn, :admin_webauthn_attempts) || 0
        # Same per-user bucket as the TOTP path — see admin_totp_verify/2.
        sudo_locked? = RateLimits.check_admin_sudo(user.id) != :ok

        cond do
          sudo_locked? or attempts >= @max_totp_attempts ->
            Logger.warning(
              "auth.admin_webauthn_lockout: user_id=#{user.id} ip=#{remote_ip(conn)}"
            )

            conn
            |> delete_session(:admin_webauthn_attempts)
            |> put_flash(:error, gettext("Too many failed attempts. Please try again later."))
            |> redirect(to: "/")

          true ->
            case Baudrate.Auth.WebAuthnChallenges.pop(token, user.id, :authentication) do
              {:ok, challenge} ->
                case Auth.finish_authentication(
                       user,
                       cid_b64,
                       ad_b64,
                       cdj_b64,
                       sig_b64,
                       challenge
                     ) do
                  {:ok, _credential} ->
                    Logger.info(
                      "auth.admin_webauthn_verify_success: user_id=#{user.id} ip=#{remote_ip(conn)}"
                    )

                    conn
                    |> delete_session(:admin_webauthn_attempts)
                    |> put_session(:admin_totp_verified_at, System.system_time(:second))
                    |> redirect(to: return_to)

                  {:error, reason} ->
                    Logger.warning(
                      "auth.admin_webauthn_verify_failure: user_id=#{user.id} attempt=#{attempts + 1} reason=#{inspect(reason)} ip=#{remote_ip(conn)}"
                    )

                    conn
                    |> put_session(:admin_webauthn_attempts, attempts + 1)
                    |> put_flash(
                      :error,
                      gettext("Security key verification failed. Please try again.")
                    )
                    |> redirect(to: "/admin/verify?return_to=#{URI.encode_www_form(return_to)}")
                end

              {:error, :not_found} ->
                Logger.warning(
                  "auth.admin_webauthn_invalid_challenge: user_id=#{user.id} ip=#{remote_ip(conn)}"
                )

                conn
                |> put_session(:admin_webauthn_attempts, attempts + 1)
                |> put_flash(
                  :error,
                  gettext("Security key verification failed. Please try again.")
                )
                |> redirect(to: "/admin/verify?return_to=#{URI.encode_www_form(return_to)}")
            end
        end

      {:ok, _non_admin} ->
        conn
        |> put_flash(:error, gettext("Access denied."))
        |> redirect(to: "/")

      _ ->
        conn
        |> put_flash(:error, gettext("Session expired. Please log in again."))
        |> redirect(to: "/login")
    end
  end

  @doc "Acknowledges that the user has saved their recovery codes and redirects to home."
  def ack_recovery_codes(conn, _params) do
    conn
    |> delete_session(:recovery_codes)
    |> redirect(to: "/")
  end

  @doc """
  Signs out the session that has just requested its account's deletion
  (ADR 0072), posted by `/profile/account`'s hidden form — a LiveView cannot
  clear its own cookie.

  Unlike `delete/2` it keeps the flash (renewing the session instead of
  dropping it), because the member needs to be told when the deletion will
  happen and that signing in cancels it. The date comes from the pending
  row of this session's own user, never from the request.
  """
  def deletion_requested(conn, _params) do
    token = get_session(conn, :session_token)

    deletion =
      with token when is_binary(token) <- token,
           {:ok, user} <- Auth.get_user_by_session_token(token) do
        # The date is shown in the member's own zone, as their pages were.
        BaudrateWeb.TimeZone.put(user.time_zone)
        Baudrate.AccountDeletion.open(user.id)
      else
        _ -> nil
      end

    if token, do: Auth.delete_session_by_token(token)

    conn =
      conn
      |> configure_session(renew: true)
      |> clear_session()

    conn =
      case deletion do
        %{execute_after: at} ->
          put_flash(
            conn,
            :info,
            gettext(
              "Your account will be deleted on %{date}. Sign in before then to cancel.",
              date: BaudrateWeb.Helpers.format_datetime(at)
            )
          )

        nil ->
          conn
      end

    redirect(conn, to: "/login")
  end

  @doc "Logs out the user by deleting the server-side session and dropping the cookie."
  def delete(conn, _params) do
    session_token = get_session(conn, :session_token)

    if session_token do
      Logger.info("auth.logout: ip=#{remote_ip(conn)}")
      Auth.delete_session_by_token(session_token)
    end

    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  # Creates a server-side session, stores session_token and refresh_token
  # in the cookie, clears all intermediate auth keys (user_id, totp_*),
  # renews the session ID to prevent fixation, and redirects to the given path.
  #
  # When `redirect_to` is the default `"/"`, checks for a `:return_to` key
  # in the cookie session (set by `ShareTargetController` for unauthenticated
  # share attempts). The stored path is sanitized and consumed on use.
  #
  # It is also the one place an IP ban is checked for sign-in (Phase 5E),
  # because every path that signs somebody in — the password step, TOTP,
  # recovery codes, first-time TOTP setup — ends here, and it is the step that
  # actually mints the session. `LoginLive` checks first so a banned visitor
  # is refused before their password is tested; this is the backstop that no
  # new sign-in path can route around.
  #
  # And it is where a pending account deletion is cancelled (ADR 0072):
  # signing in is how a member says they are staying. It runs after the IP
  # ban, so a banned address cannot cancel one, and after a status backstop —
  # the TOTP and recovery-code steps re-read the user from the cookie, so a
  # sign-in racing the deletion sweep must still find the account gone.
  defp establish_session(conn, user, redirect_to \\ "/") do
    cond do
      Auth.ip_banned?(conn.remote_ip) ->
        Logger.warning(
          "auth.ip_banned: user_id=#{user.id} ip=#{remote_ip(conn)} step=establish_session"
        )

        refuse_sign_in(conn, BaudrateWeb.Helpers.ip_banned_message())

      user.status not in ["active", "pending"] ->
        Logger.warning(
          "auth.sign_in_refused: user_id=#{user.id} status=#{user.status} step=establish_session"
        )

        refuse_sign_in(conn, gettext("Invalid session."))

      true ->
        case Baudrate.AccountDeletion.cancel_pending(user.id, "signed_in") do
          :executing ->
            refuse_sign_in(conn, gettext("This account is being deleted."))

          :cancelled ->
            conn
            |> add_info(gettext("Your account deletion has been cancelled."))
            |> do_establish_session(user, redirect_to)

          :none ->
            do_establish_session(conn, user, redirect_to)
        end
    end
  end

  # A half-finished sign-in (password verified, TOTP pending) must not
  # survive a refusal.
  defp refuse_sign_in(conn, message) do
    conn
    |> delete_session(:user_id)
    |> delete_session(:totp_setup_secret)
    |> put_flash(:error, message)
    |> redirect(to: "/login")
  end

  # Adds to an info message already set on this response (enabling TOTP sets
  # one) instead of replacing it.
  defp add_info(conn, message) do
    case get_in(conn.private, [:phoenix_flash, "info"]) do
      existing when is_binary(existing) -> put_flash(conn, :info, existing <> " " <> message)
      _ -> put_flash(conn, :info, message)
    end
  end

  defp do_establish_session(conn, user, redirect_to) do
    final_redirect =
      if redirect_to == "/" do
        case get_session(conn, :return_to) do
          # A member who asked for a particular page gets it: they said where
          # they were going, and the first-visit step has not. It is shown on
          # their next ordinary sign-in instead.
          nil -> default_landing(user)
          path -> sanitize_return_to(path)
        end
      else
        redirect_to
      end

    opts = [
      ip_address: remote_ip(conn),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    ]

    {:ok, session_token, refresh_token} = Auth.create_user_session(user.id, opts)
    session_id = Auth.session_id_by_token(session_token)

    conn
    |> configure_session(renew: true)
    |> delete_session(:user_id)
    |> delete_session(:totp_verified)
    |> delete_session(:totp_setup_secret)
    |> delete_session(:return_to)
    |> put_session(:session_token, session_token)
    |> put_session(:refresh_token, refresh_token)
    |> put_session(:refreshed_at, DateTime.utc_now() |> DateTime.to_iso8601())
    # Tags this session's LiveView sockets so revoking the session closes them.
    |> put_session(:live_socket_id, Auth.live_socket_id(session_id))
    |> put_session(:preferred_locales, user.preferred_locales || [])
    |> redirect(to: final_redirect)
  end

  # `return_to` comes from the login form, which got it from `:require_auth`.
  # It is sanitised here and not only there: what a controller receives is
  # whatever the browser posted, whatever the page that rendered it did.
  # Falling back to "/" keeps `establish_session/3`'s own `return_to` branch
  # (the PWA share target's) reachable.
  defp login_landing(%{"return_to" => path}) when is_binary(path) do
    BaudrateWeb.Helpers.local_path(path, "/")
  end

  defp login_landing(_params), do: "/"

  # A newly registered member lands on the first-visit step (P4-D2). Accounts
  # that predate the column were backfilled by its migration, so a nil here
  # means "registered since 4D and has not seen /welcome" rather than "old".
  defp default_landing(user) do
    if Auth.onboarded?(user), do: "/", else: "/welcome"
  end

  # Failed TOTP codes at login count toward the per-account login throttle
  # (ADR 0024), so it is checked here as well as on the password step.
  defp login_throttle_seconds(user) do
    case Auth.check_login_throttle(user.username) do
      {:delay, seconds} -> seconds
      :ok -> nil
    end
  end

  defp enrolment_code_step(secret, code) do
    case Auth.match_totp_step(secret, code) do
      {:ok, step} -> step
      :error -> nil
    end
  end

  defp remote_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  # Sanitizes a return_to path stored by ShareTargetController. The rule lives
  # in `BaudrateWeb.Helpers.local_path/2` because `LocaleController` needs the
  # same one, and an open-redirect guard kept in two places is kept in one.
  defp sanitize_return_to(path), do: BaudrateWeb.Helpers.local_path(path, "/")

  defp sanitize_admin_return_to(nil), do: "/admin/settings"

  defp sanitize_admin_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/admin/") &&
         !String.contains?(path, "..") &&
         !String.contains?(path, "//") &&
         !String.contains?(path, "\\") &&
         !String.contains?(path, "\n") &&
         !String.contains?(path, "\r") &&
         !String.contains?(path, "@") &&
         !String.contains?(path, "\0") do
      path
    else
      "/admin/settings"
    end
  end
end
