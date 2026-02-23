defmodule BaudrateWeb.LoginLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Auth.LoginAttempt
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

  test "shows throttle message when account has too many failures", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for _ <- 1..15 do
      Repo.insert!(%LoginAttempt{
        username: "throttled_user",
        ip_address: "127.0.0.1",
        success: false,
        inserted_at: now
      })
    end

    {:ok, lv, _html} = live(conn, "/login")

    html =
      lv
      |> form("form[phx-submit]", login: %{username: "throttled_user", password: "WrongPass1!!"})
      |> render_submit()

    assert html =~ "Account temporarily locked"
  end

  test "records failed login attempt in database", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/login")

    lv
    |> form("form[phx-submit]", login: %{username: "attempt_user", password: "WrongPass1!!"})
    |> render_submit()

    attempts = Repo.all(from a in LoginAttempt, where: a.username == "attempt_user")
    assert length(attempts) == 1
    assert hd(attempts).success == false
  end
end
