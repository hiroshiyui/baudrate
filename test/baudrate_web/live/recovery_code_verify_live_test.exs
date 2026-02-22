defmodule BaudrateWeb.RecoveryCodeVerifyLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  test "redirects to /login without session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/totp/recovery")
  end

  test "renders form for password-authenticated user", %{conn: conn} do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, _lv, html} = live(conn, "/totp/recovery")

    assert html =~ "Recovery Code"
    assert html =~ "Verify"
  end

  test "invalid code format shows error flash", %{conn: conn} do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, lv, _html} = live(conn, "/totp/recovery")

    html =
      lv
      |> form("form[phx-submit]", recovery: %{code: "0000-0000"})
      |> render_submit()

    assert html =~ "valid recovery code"
  end

  test "valid code format triggers phx-trigger-action", %{conn: conn} do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, lv, _html} = live(conn, "/totp/recovery")

    html =
      lv
      |> form("form[phx-submit]", recovery: %{code: "abcd-ef23"})
      |> render_submit()

    # phx-trigger-action causes the hidden form to fire a POST
    assert html =~ ~s(phx-trigger-action)
  end
end
