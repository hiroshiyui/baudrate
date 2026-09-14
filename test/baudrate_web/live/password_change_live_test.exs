defmodule BaudrateWeb.PasswordChangeLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Auth.{LoginAttempt, UserSession}
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting
  alias BaudrateWeb.RateLimiter.Sandbox

  @password "Password123!x"
  @new "N3w-Passw0rd!x"

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp submit(lv, params) do
    lv |> form("#password-change-form", password_change: params) |> render_submit()
  end

  defp failed_attempts(user) do
    Repo.aggregate(
      from(a in LoginAttempt, where: a.username == ^user.username and a.success == false),
      :count
    )
  end

  test "redirects to /login when not authenticated" do
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(Phoenix.ConnTest.build_conn(), "/profile/password")
  end

  test "renders the form with requirements; no TOTP field without TOTP", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/profile/password")

    assert has_element?(lv, "#password_change_current_password")
    assert has_element?(lv, "#password_change_password")
    assert has_element?(lv, "#password-change-strength")
    refute has_element?(lv, "#password_change_code")
  end

  test "an invalid new password is reported without a re-authentication attempt",
       %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, "/profile/password")

    html =
      submit(lv, %{
        current_password: "wrong-anyway",
        password: "short",
        password_confirmation: "short"
      })

    assert html =~ "Please fix the problems with the new password."
    assert has_element?(lv, "#password-change-password-errors")
    assert failed_attempts(user) == 0
  end

  test "reusing the current password is refused", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/profile/password")

    submit(lv, %{
      current_password: @password,
      password: @password,
      password_confirmation: @password
    })

    assert has_element?(
             lv,
             "#password-change-password-errors",
             "must be different from your current password"
           )
  end

  test "a wrong current password is refused and recorded", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, "/profile/password")

    html = submit(lv, %{current_password: "wrong", password: @new, password_confirmation: @new})

    assert html =~ "Invalid credentials"
    assert failed_attempts(user) == 1
    assert Auth.verify_password(Repo.reload!(user), @password)
  end

  test "success changes the password, signs out other sessions, keeps this one",
       %{conn: conn, user: user} do
    {:ok, other_token, _} = Auth.create_user_session(user.id)
    this_token = Plug.Conn.get_session(conn, :session_token)

    {:ok, lv, _html} = live(conn, "/profile/password")

    submit(lv, %{current_password: @password, password: @new, password_confirmation: @new})

    assert_redirect(lv, "/profile")
    assert Auth.verify_password(Repo.reload!(user), @new)
    assert {:ok, _} = Auth.get_user_by_session_token(this_token)
    assert {:error, :not_found} = Auth.get_user_by_session_token(other_token)
    assert Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count) == 1
  end

  test "accounts with TOTP must also give the current code", %{conn: conn, user: user} do
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)

    {:ok, lv, _html} = live(conn, "/profile/password")
    assert has_element?(lv, "#password_change_code")

    html =
      submit(lv, %{
        current_password: @password,
        code: "000000",
        password: @new,
        password_confirmation: @new
      })

    assert html =~ "Invalid credentials"
    assert Auth.verify_password(Repo.reload!(user), @password)

    submit(lv, %{
      current_password: @password,
      code: totp_code(secret),
      password: @new,
      password_confirmation: @new
    })

    assert_redirect(lv, "/profile")
  end

  test "is refused when the per-user re-authentication limit is exhausted", %{conn: conn} do
    Sandbox.set_fun(fn
      "reauth:" <> _, _scale, _limit -> {:deny, 900_000}
      _bucket, _scale, _limit -> {:allow, 1}
    end)

    {:ok, lv, _html} = live(conn, "/profile/password")

    html = submit(lv, %{current_password: @password, password: @new, password_confirmation: @new})

    assert html =~ "Too many attempts"
  end
end
