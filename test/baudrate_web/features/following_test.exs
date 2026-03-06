defmodule BaudrateWeb.Features.FollowingTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "following page is accessible when logged in", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/following")
    |> assert_has(Query.css("h1", text: "Following"))
  end

  feature "following page shows empty state", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/following")
    |> assert_has(Query.text("haven't followed anyone yet"))
  end
end
