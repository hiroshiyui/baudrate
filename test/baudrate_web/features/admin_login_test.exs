defmodule BaudrateWeb.Features.AdminLoginTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "an admin signs in with TOTP and passes sudo verification", %{session: session} do
    {session, admin, secret} = log_in_admin_via_browser(session)

    session
    |> visit_admin("/admin/settings", {admin, secret})
    |> assert_has(Query.css("#eua-form"))
  end
end
