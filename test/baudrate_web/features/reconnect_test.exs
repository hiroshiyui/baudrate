defmodule BaudrateWeb.Features.ReconnectTest do
  @moduledoc """
  The server drops a live page's socket while its session stays valid, and the
  page comes back.

  This is what a deploy, a restart or a lost network does to every open page.
  The client's job is to reconnect, rejoin the LiveView through the auth hooks
  and resubscribe, so an update made in the meantime still arrives. Nothing but
  a browser runs that code: the phoenix.js connection layer, LiveView's close
  handling and the graceful-reconnect flash in `app.js`, so this is the gate for
  phoenix.js and LiveView client bumps beside the revocation tests in
  `profile_settings_test.exs` and `sign_out_everywhere_test.exs`.

  The drop kills the socket's connection process, so the connection ends with
  no close code the client could read as an instruction. It is deliberately not
  the `"disconnect"` broadcast: since Phoenix 1.8.16 that closes with 1000,
  which LiveView answers with a delayed reload, and the app only ever sends it
  to a session it is revoking, whose pages leave through `AuthHooks` instead
  (`doc/gotchas.md`, "A revoked session's pages leave by redirect").
  """
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  import Ecto.Query, only: [from: 2]

  alias Baudrate.{Auth, Messaging, Repo}
  alias Baudrate.Auth.UserSession

  # Counts socket closes seen by the page, so the test knows the drop happened
  # before it asserts the recovery (a reconnect can be faster than a poll), and
  # marks the page so a reload (LiveView's failsafe for close code 1000) is told
  # apart from a reconnect.
  @count_drops """
  window.__samePage = true;
  window.__drops = 0;
  window.liveSocket.getSocket().onClose(() => { window.__drops += 1; });
  """

  feature "a page whose socket the server dropped reconnects and keeps receiving updates", %{
    session: session
  } do
    recipient = setup_user("user")
    sender = setup_user("user")

    session =
      session
      |> log_in_via_browser(recipient)
      |> visit("/messages")
      |> assert_has(Query.text("No messages yet."))
      |> assert_has(Query.css("[data-phx-main].phx-connected"))
      |> execute_script(@count_drops)

    # Every socket process of the member's sessions is subscribed to its
    # `live_socket_id` topic. The session row stays: the page must reconnect
    # rather than leave.
    socket_pids =
      Repo.all(from s in UserSession, where: s.user_id == ^recipient.id, select: s.id)
      |> Enum.flat_map(&Registry.lookup(Baudrate.PubSub, Auth.live_socket_id(&1)))
      |> Enum.map(fn {pid, _} -> pid end)

    assert socket_pids != []
    Enum.each(socket_pids, &Process.exit(&1, :kill))

    wait_until(session, "return window.__drops > 0", "the socket was never closed")
    assert_has(session, Query.css("[data-phx-main].phx-connected"))
    assert current_path(session) == "/messages"

    # Sent after the drop, so it can only arrive over a subscription the
    # rejoined view made.
    {:ok, conversation} = Messaging.find_or_create_conversation(sender, recipient)
    {:ok, _} = Messaging.create_message(conversation, sender, %{"body" => "Still here?"})

    assert_has(session, Query.css(".conversation", text: sender.username))

    # A full reload would also list the conversation; a reconnect keeps the
    # page's JavaScript state.
    assert js_value(session, "return window.__samePage === true"),
           "the page was reloaded instead of reconnecting"
  end

  defp wait_until(session, script, message, tries \\ 50)
  defp wait_until(_session, _script, message, 0), do: flunk(message)

  defp wait_until(session, script, message, tries) do
    if js_value(session, script) do
      session
    else
      Process.sleep(100)
      wait_until(session, script, message, tries - 1)
    end
  end
end
