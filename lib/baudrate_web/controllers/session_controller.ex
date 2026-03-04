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

  ## Admin Sudo Mode

  `admin_totp_verify/2` handles TOTP re-verification for admin sudo mode.
  After 5 failed attempts (`admin_totp_attempts`), the admin is locked out
  of admin pages but the session is NOT dropped (they remain logged in).
  On success, `admin_totp_verified_at` (Unix timestamp) is set in the
  cookie session, granting admin access for 10 minutes.

  ## Security Logging

  All auth events are logged with structured prefixes (`auth.login_success`,
  `auth.totp_lockout`, etc.) including `user_id` and `ip` for audit trails.
  """

  use BaudrateWeb, :controller

  require Logger

  alias Baudrate.Auth

  @max_totp_attempts 5

  @doc "Verifies the short-lived Phoenix.Token from LoginLive and routes to the next auth step."
  def create(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "user_auth", token, max_age: 60) do
      {:ok, user_id} ->
        user = Auth.get_user(user_id)

        if user && user.status != "banned" do
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
              establish_session(conn, user)
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

      Auth.valid_totp?(secret, code, since: get_session(conn, :totp_verified_at)) ->
        Logger.info("auth.totp_verify_success: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> delete_session(:totp_attempts)
        |> establish_session(user)

      true ->
        Logger.warning(
          "auth.totp_verify_failure: user_id=#{user.id} attempt=#{attempts + 1} ip=#{remote_ip(conn)}"
        )

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

      Auth.valid_totp?(secret, code) ->
        case Auth.enable_totp(user, secret) do
          {:ok, updated_user} ->
            Logger.info("auth.totp_enabled: user_id=#{user.id} ip=#{remote_ip(conn)}")
            raw_codes = Auth.generate_recovery_codes(updated_user)

            conn
            |> delete_session(:totp_setup_secret)
            |> delete_session(:totp_attempts)
            |> put_session(:recovery_codes, raw_codes)
            |> establish_session(updated_user, "/profile/recovery-codes")

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
        |> redirect(to: "/profile")
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
  after 5 failed attempts (redirects to `/` without dropping the session).
  """
  def admin_totp_verify(conn, %{"code" => code} = params) do
    session_token = get_session(conn, :session_token)
    return_to = sanitize_admin_return_to(params["return_to"])

    case session_token && Auth.get_user_by_session_token(session_token) do
      {:ok, user} when user.role.name == "admin" ->
        attempts = get_session(conn, :admin_totp_attempts) || 0
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
            |> redirect(to: "/profile")

          attempts >= @max_totp_attempts ->
            Logger.warning("auth.admin_totp_lockout: user_id=#{user.id} ip=#{remote_ip(conn)}")

            conn
            |> delete_session(:admin_totp_attempts)
            |> put_flash(:error, gettext("Too many failed attempts. Please try again later."))
            |> redirect(to: "/")

          Auth.valid_totp?(secret, code) ->
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

  @doc "Acknowledges that the user has saved their recovery codes and redirects to home."
  def ack_recovery_codes(conn, _params) do
    conn
    |> delete_session(:recovery_codes)
    |> redirect(to: "/")
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
  defp establish_session(conn, user, redirect_to \\ "/") do
    final_redirect =
      if redirect_to == "/" do
        case get_session(conn, :return_to) do
          nil -> "/"
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

    conn
    |> configure_session(renew: true)
    |> delete_session(:user_id)
    |> delete_session(:totp_verified)
    |> delete_session(:totp_verified_at)
    |> delete_session(:totp_setup_secret)
    |> delete_session(:return_to)
    |> put_session(:session_token, session_token)
    |> put_session(:refresh_token, refresh_token)
    |> put_session(:refreshed_at, DateTime.utc_now() |> DateTime.to_iso8601())
    |> put_session(:preferred_locales, user.preferred_locales || [])
    |> redirect(to: final_redirect)
  end

  defp remote_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  # Sanitizes a return_to path stored by ShareTargetController.
  # Only allows local paths starting with "/" — rejects schemes, double slashes,
  # path traversal, control characters, and "@" (authority component).
  defp sanitize_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/") &&
         !String.starts_with?(path, "//") &&
         !String.contains?(path, "..") &&
         !String.contains?(path, "\\") &&
         !String.contains?(path, "\n") &&
         !String.contains?(path, "\r") &&
         !String.contains?(path, "@") &&
         !String.contains?(path, "\0") do
      path
    else
      "/"
    end
  end

  defp sanitize_return_to(_), do: "/"

  defp sanitize_admin_return_to(nil), do: "/admin/settings"

  defp sanitize_admin_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/admin/") &&
         !String.contains?(path, "..") &&
         !String.contains?(path, "//") &&
         !String.contains?(path, "\\") &&
         !String.contains?(path, "\n") &&
         !String.contains?(path, "\r") &&
         !String.contains?(path, "@") do
      path
    else
      "/admin/settings"
    end
  end
end
