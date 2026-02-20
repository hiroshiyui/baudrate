defmodule BaudrateWeb.TotpSetupLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  test "renders setup form with QR code for admin", %{conn: conn} do
    user = setup_user("admin")
    secret = Auth.generate_totp_secret()
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id, totp_setup_secret: secret})
    {:ok, _lv, html} = live(conn, "/totp/setup")

    assert html =~ "Set Up Two-Factor Authentication"
    assert html =~ "<svg"
    assert html =~ "requires two-factor authentication"
    assert html =~ "Verification Code"
  end

  test "renders setup form for optional user", %{conn: conn} do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id, totp_setup_secret: secret})
    {:ok, _lv, html} = live(conn, "/totp/setup")

    assert html =~ "Set Up Two-Factor Authentication"
    assert html =~ "enable two-factor authentication"
  end

  test "redirects to /login without session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/totp/setup")
  end

  test "redirects to /login without totp_setup_secret in session", %{conn: conn} do
    user = setup_user("admin")
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/totp/setup")
  end
end
