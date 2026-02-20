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

  ## Security Logging

  All auth events are logged with structured prefixes (`auth.login_success`,
  `auth.totp_lockout`, etc.) including `user_id` and `ip` for audit trails.
  """

  use BaudrateWeb, :controller

  require Logger

  alias Baudrate.Auth

  @max_totp_attempts 5

  def create(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "user_auth", token, max_age: 60) do
      {:ok, user_id} ->
        user = Auth.get_user(user_id)

        if user do
          Logger.info("auth.login_success: user_id=#{user.id} username=#{user.username} ip=#{remote_ip(conn)}")

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
          |> put_flash(:error, "Invalid session.")
          |> redirect(to: "/login")
        end

      {:error, _reason} ->
        Logger.warning("auth.invalid_token: ip=#{remote_ip(conn)}")

        conn
        |> put_flash(:error, "Invalid or expired token.")
        |> redirect(to: "/login")
    end
  end

  def totp_verify(conn, %{"code" => code}) do
    user_id = get_session(conn, :user_id)
    user = user_id && Auth.get_user(user_id)
    attempts = get_session(conn, :totp_attempts) || 0
    secret = user && Auth.decrypt_totp_secret(user)

    cond do
      is_nil(user) ->
        conn
        |> put_flash(:error, "Session expired. Please log in again.")
        |> redirect(to: "/login")

      is_nil(secret) ->
        Logger.error("auth.totp_decrypt_error: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> put_flash(:error, "TOTP configuration error. Please contact an administrator.")
        |> configure_session(drop: true)
        |> redirect(to: "/login")

      attempts >= @max_totp_attempts ->
        Logger.warning("auth.totp_lockout: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> configure_session(drop: true)
        |> put_flash(:error, "Too many failed attempts. Please log in again.")
        |> redirect(to: "/login")

      Auth.valid_totp?(secret, code, since: get_session(conn, :totp_verified_at)) ->
        Logger.info("auth.totp_verify_success: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> delete_session(:totp_attempts)
        |> establish_session(user)

      true ->
        Logger.warning("auth.totp_verify_failure: user_id=#{user.id} attempt=#{attempts + 1} ip=#{remote_ip(conn)}")

        conn
        |> put_session(:totp_attempts, attempts + 1)
        |> put_flash(:error, "Invalid verification code. Please try again.")
        |> redirect(to: "/totp/verify")
    end
  end

  def totp_enable(conn, %{"code" => code}) do
    user_id = get_session(conn, :user_id)
    user = user_id && Auth.get_user(user_id)
    secret = get_session(conn, :totp_setup_secret)
    attempts = get_session(conn, :totp_attempts) || 0

    cond do
      is_nil(user) || is_nil(secret) ->
        conn
        |> put_flash(:error, "Session expired. Please log in again.")
        |> redirect(to: "/login")

      attempts >= @max_totp_attempts ->
        Logger.warning("auth.totp_setup_lockout: user_id=#{user.id} ip=#{remote_ip(conn)}")

        conn
        |> configure_session(drop: true)
        |> put_flash(:error, "Too many failed attempts. Please log in again.")
        |> redirect(to: "/login")

      Auth.valid_totp?(secret, code) ->
        case Auth.enable_totp(user, secret) do
          {:ok, _user} ->
            Logger.info("auth.totp_enabled: user_id=#{user.id} ip=#{remote_ip(conn)}")

            conn
            |> delete_session(:totp_setup_secret)
            |> delete_session(:totp_attempts)
            |> establish_session(user)

          {:error, _changeset} ->
            Logger.error("auth.totp_enable_failed: user_id=#{user.id} ip=#{remote_ip(conn)}")

            conn
            |> put_flash(:error, "Failed to enable TOTP. Please try again.")
            |> redirect(to: "/totp/setup")
        end

      true ->
        Logger.warning("auth.totp_setup_failure: user_id=#{user.id} attempt=#{attempts + 1} ip=#{remote_ip(conn)}")

        conn
        |> put_session(:totp_attempts, attempts + 1)
        |> put_flash(:error, "Invalid verification code. Please try again.")
        |> redirect(to: "/totp/setup")
    end
  end

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
  # renews the session ID to prevent fixation, and redirects to /.
  defp establish_session(conn, user) do
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
    |> put_session(:session_token, session_token)
    |> put_session(:refresh_token, refresh_token)
    |> put_session(:refreshed_at, DateTime.utc_now() |> DateTime.to_iso8601())
    |> redirect(to: "/")
  end

  defp remote_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
