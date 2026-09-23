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

  # ADR 0071: the image is uploaded, sent on its own, and rendered from the
  # checked route — never from its path under /uploads.
  feature "an image is sent in a message and shown from the private route", %{
    session: session
  } do
    sender = setup_user("user")
    recipient = setup_user("user")
    {:ok, conversation} = Baudrate.Messaging.find_or_create_conversation(sender, recipient)

    png = Path.join(System.tmp_dir!(), "dm-feature-#{System.unique_integer([:positive])}.png")
    Image.new!(64, 48, color: [30, 120, 200]) |> Image.write!(png)
    on_exit(fn -> File.rm(png) end)

    session =
      session
      |> log_in_via_browser(sender)
      |> visit("/messages/#{conversation.id}")
      # The upload input is re-rendered when the socket connects; typing into
      # the static render's copy leaves a stale reference.
      |> assert_has(Query.css("[data-phx-main].phx-connected"))

    # Browser and test share a filesystem, so the path is typed into the file
    # input (see composer_test.exs).
    session
    |> find(Query.css(".conversation-images-input", visible: :any))
    |> Wallaby.Element.set_value(png)

    session
    |> assert_has(Query.css(".conversation-uploaded-image img"))
    |> click(Query.css("#conversation-compose-send"))
    |> assert_has(Query.css(".message-images img"))

    [image] = Baudrate.Repo.all(Baudrate.Messaging.DmImage)
    assert image.message_id

    src =
      session
      |> find(Query.css("#message-image-#{image.id} img"))
      |> Wallaby.Element.attr("src")

    assert src =~ "/messages/images/#{image.id}"
    refute src =~ image.filename

    with {:ok, path} <- Baudrate.DataPortability.Files.image_path("dm_images", image.filename),
         do: File.rm(path)
  end
end
