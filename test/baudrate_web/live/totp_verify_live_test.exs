defmodule BaudrateWeb.TotpVerifyLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query, only: [where: 2]
  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  test "renders verification form for password-authed user", %{conn: conn} do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)

    conn =
      Plug.Test.init_test_session(
        conn,
        BaudrateWeb.HalfLogin.session(Baudrate.Repo.reload!(user))
      )

    {:ok, _lv, html} = live(conn, "/totp/verify")

    assert html =~ "Two-Factor Authentication"
    assert html =~ "Verification Code"
    # Codes are single-use (ADR 0024); the hint is always there, not only after a failure.
    assert html =~ ~s(aria-describedby="totp-verify-code-hint")
    assert html =~ "Each code works only once"
  end

  test "redirects to /login without session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login" <> _}}} = live(conn, "/totp/verify")
  end

  test "valid 6-digit code triggers phx-trigger-action", %{conn: conn} do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)

    conn =
      Plug.Test.init_test_session(
        conn,
        BaudrateWeb.HalfLogin.session(Baudrate.Repo.reload!(user))
      )

    {:ok, lv, _html} = live(conn, "/totp/verify")

    html =
      lv
      |> form("form[phx-submit]", totp: %{code: "123456"})
      |> render_submit()

    assert html =~ ~s(phx-trigger-action)
  end

  test "non-numeric code shows error", %{conn: conn} do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)

    conn =
      Plug.Test.init_test_session(
        conn,
        BaudrateWeb.HalfLogin.session(Baudrate.Repo.reload!(user))
      )

    {:ok, lv, _html} = live(conn, "/totp/verify")

    html =
      lv
      |> form("form[phx-submit]", totp: %{code: "abcdef"})
      |> render_submit()

    assert html =~ "6-digit"
  end

  test "short code shows error", %{conn: conn} do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)

    conn =
      Plug.Test.init_test_session(
        conn,
        BaudrateWeb.HalfLogin.session(Baudrate.Repo.reload!(user))
      )

    {:ok, lv, _html} = live(conn, "/totp/verify")

    html =
      lv
      |> form("form[phx-submit]", totp: %{code: "123"})
      |> render_submit()

    assert html =~ "6-digit"
  end

  # A half-login is bound to the credentials it started with (HalfLogin): the
  # page refuses one kept from before a password change.
  test "redirects a half-login kept from before a password change", %{conn: conn} do
    user = setup_user("user")
    {:ok, _} = Auth.enable_totp(user, Auth.generate_totp_secret())
    stale = BaudrateWeb.HalfLogin.session(Repo.reload!(user))

    Repo.update_all(
      where(Baudrate.Setup.User, id: ^user.id),
      set: [hashed_password: Bcrypt.hash_pwd_salt("a different password 123")]
    )

    assert {:error, {:redirect, %{to: "/login"}}} =
             conn
             |> Plug.Test.init_test_session(stale)
             |> live("/totp/verify")
  end
end
