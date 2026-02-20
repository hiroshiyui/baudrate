defmodule BaudrateWeb.LoginLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  test "renders login form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/login")
    assert html =~ "Sign In"
    assert html =~ "Username"
    assert html =~ "Password"
  end

  test "shows error on invalid credentials", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/login")

    html =
      lv
      |> form("form[phx-submit]", login: %{username: "nobody", password: "WrongPass1!!"})
      |> render_submit()

    assert html =~ "Invalid username or password"
  end

  test "redirects authenticated user away from /login", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/login")
  end
end
