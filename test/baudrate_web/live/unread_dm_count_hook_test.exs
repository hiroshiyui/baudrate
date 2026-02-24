defmodule BaudrateWeb.UnreadDmCountHookTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Messaging
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "unread DM badge in navbar" do
    test "shows badge when user has unread messages", %{conn: conn, user: user} do
      other = setup_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user, other)
      {:ok, _msg} = Messaging.create_message(conv, other, %{body: "Hello!"})

      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "badge badge-primary badge-xs"
      assert html =~ "1"
    end

    test "does not show badge when no unread messages", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")

      refute html =~ "badge badge-primary badge-xs"
    end

    test "updates badge in real time when DM is received", %{conn: conn, user: user} do
      other = setup_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user, other)

      {:ok, lv, html} = live(conn, "/")
      refute html =~ "badge badge-primary badge-xs"

      # Simulate receiving a DM (creates message which broadcasts :dm_received)
      {:ok, _msg} = Messaging.create_message(conv, other, %{body: "New message!"})

      # The hook should pick up the :dm_received event and update the count
      html = render(lv)
      assert html =~ "badge badge-primary badge-xs"
      assert html =~ "1"
    end

    test "updates badge in real time when conversation is marked read", %{
      conn: conn,
      user: user
    } do
      other = setup_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user, other)
      {:ok, msg} = Messaging.create_message(conv, other, %{body: "Hello!"})

      {:ok, lv, html} = live(conn, "/")
      assert html =~ "badge badge-primary badge-xs"

      # Mark as read (broadcasts :dm_read)
      Messaging.mark_conversation_read(conv, user, msg)

      html = render(lv)
      refute html =~ "badge badge-primary badge-xs"
    end

    test "badge shows correct count for multiple unread messages", %{conn: conn, user: user} do
      other = setup_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user, other)
      {:ok, _msg1} = Messaging.create_message(conv, other, %{body: "First"})
      {:ok, _msg2} = Messaging.create_message(conv, other, %{body: "Second"})
      {:ok, _msg3} = Messaging.create_message(conv, other, %{body: "Third"})

      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "badge badge-primary badge-xs"
      assert html =~ "3"
    end

    test "badge appears on optional_auth pages when authenticated", %{conn: conn, user: user} do
      other = setup_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user, other)
      {:ok, _msg} = Messaging.create_message(conv, other, %{body: "Hello!"})

      # "/" uses optional_auth live_session
      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "badge badge-primary badge-xs"
    end
  end
end
