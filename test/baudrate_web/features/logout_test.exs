defmodule BaudrateWeb.Features.LogoutTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "logout redirects to login page", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> assert_has(Query.css("h1", text: "Welcome, #{user.username}!"))
    # The Sign Out link is inside a dropdown that may not be visible at small
    # viewport sizes. Use JS to programmatically click it.
    |> execute_script("document.querySelector(\"a[href='/logout']\").click()")
    |> assert_has(Query.css("h1", text: "Sign In"))
  end
end
