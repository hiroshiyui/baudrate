defmodule BaudrateWeb.TotpResetLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Auth.LoginAttempt
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting
  alias BaudrateWeb.RateLimiter.Sandbox

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  test "redirects to /login when not authenticated", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login" <> _}}} = live(conn, "/profile/totp-reset")
  end

  test "renders enable mode when user has no TOTP", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, "/profile/totp-reset")

    assert html =~ "Enable Two-Factor Authentication"
  end

  test "renders reset mode when user has TOTP", %{conn: conn} do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)

    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, "/profile/totp-reset")

    assert html =~ "Reset Authenticator"
    assert html =~ "Current TOTP Code"
  end

  test "shows error on invalid password", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, "/profile/totp-reset")

    html =
      lv
      |> form("form[phx-submit]", totp_reset: %{password: "wrong_password"})
      |> render_submit()

    assert html =~ "Invalid credentials"
  end

  test "lockout after 5 failed attempts redirects to /profile", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, "/profile/totp-reset")

    # Exhaust 5 attempts
    for _ <- 1..5 do
      lv
      |> form("form[phx-submit]", totp_reset: %{password: "wrong"})
      |> render_submit()
    end

    # 6th attempt triggers lockout redirect
    lv
    |> form("form[phx-submit]", totp_reset: %{password: "wrong"})
    |> render_submit()

    assert_redirect(lv, "/profile")
  end

  test "failed attempts are recorded against the account", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, "/profile/totp-reset")

    lv
    |> form("form[phx-submit]", totp_reset: %{password: "wrong"})
    |> render_submit()

    assert Repo.exists?(
             from(a in LoginAttempt, where: a.username == ^user.username and a.success == false)
           )
  end

  # The socket attempt counter resets on reload. The account throttle must not,
  # or this form becomes an unthrottled password oracle for a stolen session.
  test "the account throttle survives a reload and blocks even the right password",
       %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      LoginAttempt,
      for(
        _ <- 1..15,
        do: %{
          username: user.username,
          ip_address: "203.0.113.7",
          success: false,
          inserted_at: now
        }
      )
    )

    {:ok, lv, _html} = live(conn, "/profile/totp-reset")

    html =
      lv
      |> form("form[phx-submit]", totp_reset: %{password: "Password123!x"})
      |> render_submit()

    assert html =~ "Too many failed attempts. Please try again in"
    refute render(lv) =~ ~s(phx-trigger-action)
  end

  test "is refused when the per-user rate limit is exhausted", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    Sandbox.set_fun(fn
      "reauth:" <> _, _scale, _limit -> {:deny, 900_000}
      _bucket, _scale, _limit -> {:allow, 1}
    end)

    {:ok, lv, _html} = live(conn, "/profile/totp-reset")

    html =
      lv
      |> form("form[phx-submit]", totp_reset: %{password: "Password123!x"})
      |> render_submit()

    assert html =~ "Too many attempts. Please try again later."
  end
end
