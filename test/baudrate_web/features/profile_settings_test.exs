defmodule BaudrateWeb.Features.ProfileSettingsTest do
  @moduledoc """
  The 6E-1 settings controls a LiveView test cannot see: the device time
  zone comes from the browser's `Intl`, and signing one session out has to
  close a page another browser really has open.
  """

  use BaudrateWeb.FeatureCase, async: false

  alias Baudrate.Repo

  @moduletag :feature

  feature "the device's time zone button saves the zone the browser reports", %{
    session: session
  } do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/profile/account")
    |> assert_has(Query.css("#profile-time-zone-device"))
    |> click(Query.css("#profile-time-zone-device"))
    |> assert_has(Query.text("Time zone updated."))

    zone = Repo.reload!(user).time_zone
    assert zone in Baudrate.Timezone.identifiers()
    assert_has(session, Query.css("#footer-time-zone", text: zone))
  end

  feature "signing one session out disconnects that browser's open page", %{
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
    |> fill_in(Query.css("#security_reauth_password"), with: "Password123!x")
    |> click(Query.css("#profile-security-reauth-submit"))
    |> assert_has(Query.css("#profile-security-unlocked"))

    # The current session never offers the button, so the one there is the
    # other browser's. `data-confirm` asks through `window.confirm`.
    session
    |> execute_script("window.confirm = () => true")
    |> click(Query.css(".profile-session-revoke", count: 1))

    assert_has(session, Query.css("#profile-sessions-status", text: "Session signed out."))
    wait_for_path(other_device, "/login")
  end

  # ADR 0072: the page signs its own session out through a form post, and the
  # next sign-in cancels the deletion — both need a real browser to see.
  feature "asking to delete the account signs out, and signing in again cancels it", %{
    session: session
  } do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/profile/account")
    |> fill_in(Query.css("#account-deletion-password"), with: "Password123!x")
    |> execute_script("window.confirm = () => true")
    |> click(Query.css("#account-deletion-submit"))
    |> wait_for_path("/login")
    |> assert_has(Query.text("will be deleted on", minimum: 1))

    assert Baudrate.AccountDeletion.open(user.id)

    session
    |> submit_login_form(user, "Password123!x")
    |> assert_has(Query.text("Your account deletion has been cancelled.", minimum: 1))

    refute Baudrate.AccountDeletion.open(user.id)
  end
end
