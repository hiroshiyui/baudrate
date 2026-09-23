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

    # The revoked session's LiveView is disconnected and cannot remount, so
    # the page it had open sends it to sign in without any action.
    wait_for_path(other_device, "/login")

    session
    |> visit("/bookmarks")
    |> assert_has(Query.css("#bookmarks-heading"))
  end
end
