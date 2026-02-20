defmodule BaudrateWeb.TotpVerifyLiveTest do
  use BaudrateWeb.ConnCase

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

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, _lv, html} = live(conn, "/totp/verify")

    assert html =~ "Two-Factor Authentication"
    assert html =~ "Verification Code"
  end

  test "redirects to /login without session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/totp/verify")
  end
end
