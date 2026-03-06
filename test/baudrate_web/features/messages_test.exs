defmodule BaudrateWeb.Features.MessagesTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "messages page is accessible when logged in", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/messages")
    |> assert_has(Query.css("h1", text: "Messages"))
  end

  feature "messages page shows empty state", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/messages")
    |> assert_has(Query.text("No messages yet."))
  end

  feature "new message page is accessible", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/messages/new")
    |> assert_has(Query.css("h1", text: "New Message"))
  end
end
