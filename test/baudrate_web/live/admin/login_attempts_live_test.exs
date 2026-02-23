defmodule BaudrateWeb.Admin.LoginAttemptsLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  test "admin can view login attempts page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/login-attempts")
    assert html =~ "Login Attempts"
    assert html =~ "Filter by username"
  end

  test "non-admin is redirected away", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/login-attempts")
  end

  test "displays login attempt records", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    Auth.record_login_attempt("testuser", "10.0.0.1", false)
    Auth.record_login_attempt("testuser", "10.0.0.2", true)

    {:ok, _lv, html} = live(conn, "/admin/login-attempts")
    assert html =~ "testuser"
    assert html =~ "10.0.0.1"
    assert html =~ "Failed"
    assert html =~ "Success"
  end

  test "admin can filter by username", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    Auth.record_login_attempt("alice", "10.0.0.1", false)
    Auth.record_login_attempt("bob", "10.0.0.1", false)

    {:ok, lv, _html} = live(conn, "/admin/login-attempts")

    html = lv |> form("form", %{username: "alice"}) |> render_submit()
    assert html =~ "alice"
    refute html =~ "bob"
  end
end
