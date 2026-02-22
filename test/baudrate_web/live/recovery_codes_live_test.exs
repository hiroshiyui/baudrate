defmodule BaudrateWeb.RecoveryCodesLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  test "redirects to /login when not authenticated", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/profile/recovery-codes")
  end

  test "redirects to / when no recovery codes in session", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/profile/recovery-codes")
  end

  test "displays recovery codes when present in session", %{conn: conn} do
    user = setup_user("user")
    {:ok, session_token, refresh_token} = Baudrate.Auth.create_user_session(user.id)

    codes = ["abcd-ef23", "wxyz-mn45", "ghij-kl67"]

    conn =
      Plug.Test.init_test_session(conn, %{
        session_token: session_token,
        refresh_token: refresh_token,
        refreshed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        recovery_codes: codes
      })

    {:ok, _lv, html} = live(conn, "/profile/recovery-codes")

    assert html =~ "Recovery Codes"
    assert html =~ "abcd-ef23"
    assert html =~ "wxyz-mn45"
    assert html =~ "ghij-kl67"
  end
end
