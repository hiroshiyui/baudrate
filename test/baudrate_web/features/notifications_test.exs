defmodule BaudrateWeb.Features.NotificationsTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "notifications page is accessible when logged in", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/notifications")
    |> assert_has(Query.css("h1", text: "Notifications"))
  end

  feature "notifications page shows empty state", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/notifications")
    |> assert_has(Query.text("No notifications"))
  end
end
