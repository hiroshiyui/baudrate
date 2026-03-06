defmodule BaudrateWeb.Features.InvitesTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "invites page is accessible when logged in", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/invites")
    |> assert_has(Query.css("h1", text: "My Invites"))
  end

  feature "invites page shows generate button", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/invites")
    |> assert_has(Query.button("Generate Code"))
  end
end
