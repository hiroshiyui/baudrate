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

  feature "a member sends a message and it arrives on the recipient's open inbox", %{
    session: session
  } do
    sender = setup_user("user")
    recipient = setup_user("user")

    inbox =
      start_another_session()
      |> log_in_via_browser(recipient)
      |> visit("/messages")
      |> assert_has(Query.text("No messages yet."))

    session
    |> log_in_via_browser(sender)
    |> visit("/messages/new")
    |> fill_in(Query.css("#conversation-recipient-search"), with: recipient.username)
    |> click(Query.css("#conversation-search-result-#{recipient.id}"))
    |> fill_in(Query.css("#conversation-compose-input"), with: "Hello over there")
    |> click(Query.css("#conversation-compose-send"))
    |> assert_has(Query.css("#message-list", text: "Hello over there"))

    assert js_value(session, "return document.getElementById('conversation-compose-input').value") ==
             ""

    # No reload: the inbox lists the new conversation as it arrives.
    inbox
    |> assert_has(Query.css(".conversation", text: sender.username))
    |> click(Query.css(".conversation", text: sender.username))
    |> assert_has(Query.css("#message-list", text: "Hello over there"))
  end
end
