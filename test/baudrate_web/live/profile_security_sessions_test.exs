defmodule BaudrateWeb.ProfileSecuritySessionsTest do
  @moduledoc """
  The session list on `/profile/security` (6E-1). Anyone signed in sees which
  browsers are signed in; the addresses they came from and the per-session
  sign-out need the same step-up unlock as security keys, because a stolen
  cookie must neither learn the member's other locations nor sign the real
  member out and keep its own session.
  """

  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Auth.UserSession
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  @password "Password123!x"
  @firefox_linux "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)

    {:ok, token, _} =
      Auth.create_user_session(user.id, user_agent: @firefox_linux, ip_address: "198.51.100.4")

    %{conn: conn, user: user, other_id: Auth.session_id_by_token(token)}
  end

  defp unlock(lv) do
    lv
    |> form("#profile-security-reauth-form", security_reauth: %{password: @password})
    |> render_submit()
  end

  test "lists sessions, marks this one, and hides addresses while locked", ctx do
    {:ok, lv, _html} = live(ctx.conn, "/profile/security")

    assert has_element?(lv, "#profile-session-#{ctx.other_id}", "Firefox on Linux")
    assert has_element?(lv, ".profile-session-current", "This session")
    refute render(lv) =~ "198.51.100.4"
    refute render(lv) =~ "Mozilla/5.0"
    refute has_element?(lv, "#profile-session-revoke-#{ctx.other_id}")
    assert has_element?(lv, "#profile-sessions-locked-hint")
  end

  test "after the unlock, shows addresses and signs one session out", ctx do
    {:ok, lv, _html} = live(ctx.conn, "/profile/security")
    unlock(lv)

    assert render(lv) =~ "198.51.100.4"
    refute has_element?(lv, ".profile-session-current + .profile-session-revoke")

    lv |> element("#profile-session-revoke-#{ctx.other_id}") |> render_click()

    refute Repo.get(UserSession, ctx.other_id)
    refute has_element?(lv, "#profile-session-#{ctx.other_id}")
    assert has_element?(lv, "#profile-sessions-status", "Session signed out.")
  end

  test "the current session offers no sign-out button", ctx do
    {:ok, lv, _html} = live(ctx.conn, "/profile/security")
    unlock(lv)

    [current] = Auth.list_sessions(ctx.user.id) |> Enum.reject(&(&1.id == ctx.other_id))
    refute has_element?(lv, "#profile-session-revoke-#{current.id}")
  end

  test "a crafted event without the unlock signs nothing out", ctx do
    {:ok, lv, _html} = live(ctx.conn, "/profile/security")

    render_hook(lv, "revoke_session", %{"id" => to_string(ctx.other_id)})

    assert Repo.get(UserSession, ctx.other_id)
  end

  test "another member's session id signs nothing out", ctx do
    stranger = setup_user("user")
    {:ok, token, _} = Auth.create_user_session(stranger.id)
    theirs = Auth.session_id_by_token(token)

    {:ok, lv, _html} = live(ctx.conn, "/profile/security")
    unlock(lv)
    render_hook(lv, "revoke_session", %{"id" => to_string(theirs)})

    assert Repo.get(UserSession, theirs)
  end
end
