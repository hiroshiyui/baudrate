defmodule BaudrateWeb.Features.SignOutEverywhereTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "signing out everywhere else disconnects another browser's open page", %{
    session: session
  } do
    user = setup_user("user")

    other_device =
      start_another_session()
      |> log_in_via_browser(user)
      |> visit("/bookmarks")
      |> assert_has(Query.css("#bookmarks-heading"))

    session
    |> log_in_via_browser(user)
    |> visit("/profile/security")
    |> fill_in(Query.css("#sign_out_password"), with: "Password123!x")
    |> click(Query.css("#profile-sign-out-everywhere-submit"))
    |> assert_has(Query.text("Signed out 1 other session."))

    # The revoked session's LiveView is told and sends its page to sign in
    # without any action (`AuthHooks`); the socket close follows a second
    # later as the backstop.
    wait_for_path(other_device, "/login")

    # The sign-in page must not inherit the revoked session's socket id
    # (`ForgetRevokedSession`): if it did, the backstop would close its socket
    # with code 1000 and LiveView would reload it 5-10 s later. Waiting out
    # the one-second backstop is the point here, not an ordering shortcut.
    Process.sleep(2_000)

    assert js_value(other_device, "return window.liveSocket.isConnected()"),
           "the sign-in page's socket was closed by the revoked session's backstop"

    assert current_path(other_device) == "/login"

    session
    |> visit("/bookmarks")
    |> assert_has(Query.css("#bookmarks-heading"))
  end
end
