defmodule BaudrateWeb.TotpResetLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  test "redirects to /login when not authenticated", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/profile/totp-reset")
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
end
