defmodule BaudrateWeb.Features.SecurityKeysTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "an admin registers a security key and uses it for sudo verification", %{
    session: session
  } do
    {session, admin, secret} = log_in_admin_via_browser(session)
    {session, _authenticator} = add_virtual_authenticator(session)

    session
    |> visit("/profile")
    |> fill_in(Query.css("#security_reauth_password"), with: "Password123!x")
    |> fill_in(Query.css("#security_reauth_code"), with: totp_code(admin, secret))
    |> click(Query.css("#profile-security-reauth-submit"))
    |> click(Query.css("#profile-security-key-register"))
    |> assert_has(Query.css(".security-key", count: 1))

    session
    |> visit("/admin/settings")
    |> click(Query.css("#admin-totp-verify-webauthn-button"))
    |> assert_has(Query.css("#eua-form"))
  end
end
