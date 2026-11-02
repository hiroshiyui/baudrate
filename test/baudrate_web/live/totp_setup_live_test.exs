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

    conn =
      Plug.Test.init_test_session(conn, %{
        user_id: user.id,
        totp_setup_secret: secret,
        totp_setup_user_id: user.id
      })

    {:ok, _lv, html} = live(conn, "/totp/setup")

    assert html =~ "Set Up Two-Factor Authentication"
    assert html =~ "data:image/svg+xml;base64,"
    assert html =~ "requires two-factor authentication"
    assert html =~ "Verification Code"
  end

  test "renders setup form for optional user", %{conn: conn} do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()

    conn =
      Plug.Test.init_test_session(conn, %{
        user_id: user.id,
        totp_setup_secret: secret,
        totp_setup_user_id: user.id
      })

    {:ok, _lv, html} = live(conn, "/totp/setup")

    assert html =~ "Set Up Two-Factor Authentication"
    assert html =~ "enable two-factor authentication"
  end

  test "redirects to /login without session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login" <> _}}} = live(conn, "/totp/setup")
  end

  # The page shows a pending enrolment secret only to the account it was
  # issued to, and never to an account that already has a second factor
  # (see SessionControllerTest, "a TOTP enrolment secret is bound...").
  test "redirects to /login for a secret issued to another account", %{conn: conn} do
    owner = setup_user("user")
    other = setup_user("user")

    conn =
      Plug.Test.init_test_session(conn, %{
        user_id: other.id,
        totp_setup_secret: Auth.generate_totp_secret(),
        totp_setup_user_id: owner.id
      })

    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/totp/setup")
  end

  test "redirects to /login when the account already has TOTP", %{conn: conn} do
    user = setup_user("user")
    {:ok, user} = Auth.enable_totp(user, Auth.generate_totp_secret())

    conn =
      Plug.Test.init_test_session(conn, %{
        user_id: user.id,
        totp_setup_secret: Auth.generate_totp_secret(),
        totp_setup_user_id: user.id
      })

    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/totp/setup")
  end

  test "redirects to /login without totp_setup_secret in session", %{conn: conn} do
    user = setup_user("admin")
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:error, {:redirect, %{to: "/login" <> _}}} = live(conn, "/totp/setup")
  end
end
