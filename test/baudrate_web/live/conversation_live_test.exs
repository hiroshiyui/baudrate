defmodule BaudrateWeb.ConversationLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Messaging
  alias Baudrate.Setup.Setting

  setup do
    Baudrate.Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Baudrate.Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    user = setup_user("user")
    other = setup_user("user")
    %{user: user, other: other}
  end

  describe "authenticated access" do
    test "redirects to login when not authenticated", %{conn: conn, other: other} do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(conn, "/messages/new?to=#{other.username}")
    end

    test "renders new conversation form", %{conn: conn, user: user, other: other} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/new?to=#{other.username}")
      assert render(view) =~ other.username
      assert render(view) =~ "not end-to-end encrypted"
    end

    test "renders existing conversation", %{conn: conn, user: user, other: other} do
      {:ok, conv} = Messaging.find_or_create_conversation(user, other)
      {:ok, _msg} = Messaging.create_message(conv, user, %{body: "Test message"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/#{conv.id}")
      assert render(view) =~ "Test message"
    end

    test "non-participant is redirected", %{conn: conn} do
      user_a = setup_user("user")
      user_b = setup_user("user")
      viewer = setup_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      conn = log_in_user(conn, viewer)
      assert {:error, {:redirect, _}} = live(conn, "/messages/#{conv.id}")
    end
  end

  describe "sending messages" do
    test "can send a message", %{conn: conn, user: user, other: other} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/new?to=#{other.username}")

      view
      |> form("form", message: %{body: "Hello there!"})
      |> render_submit()

      assert render(view) =~ "Hello there!"
    end

    test "ignores empty messages", %{conn: conn, user: user, other: other} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/new?to=#{other.username}")

      view
      |> form("form", message: %{body: "  "})
      |> render_submit()

      # Should not crash, no message added
      refute render(view) =~ "chat-bubble"
    end
  end

  describe "recipient selection" do
    test "/messages/new without params renders recipient search UI", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, "/messages/new")
      assert html =~ "Search by username"
      assert has_element?(view, "input[name='search[query]']")
    end

    test "typing a username shows matching results", %{conn: conn, user: user, other: other} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/new")

      html =
        view
        |> form("form", search: %{query: String.slice(other.username, 0, 5)})
        |> render_change()

      assert html =~ other.username
    end

    test "clicking a result navigates to /messages/new?to=username", %{
      conn: conn,
      user: user,
      other: other
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/new")

      view
      |> form("form", search: %{query: other.username})
      |> render_change()

      {:ok, _view, html} =
        view
        |> element("button[phx-value-username='#{other.username}']")
        |> render_click()
        |> follow_redirect(conn)

      # Should now be on the new conversation page with the recipient
      assert html =~ other.username
      assert html =~ "not end-to-end encrypted"
    end

    test "current user is excluded from search results", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/new")

      html =
        view
        |> form("form", search: %{query: user.username})
        |> render_change()

      refute html =~ "phx-value-username=\"#{user.username}\""
    end
  end

  describe "deleting messages" do
    test "can delete own message", %{conn: conn, user: user, other: other} do
      {:ok, conv} = Messaging.find_or_create_conversation(user, other)
      {:ok, msg} = Messaging.create_message(conv, user, %{body: "Delete this"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/#{conv.id}")
      assert render(view) =~ "Delete this"

      view
      |> element(~s(button[phx-click="delete_message"][phx-value-id="#{msg.id}"]))
      |> render_click()

      refute render(view) =~ "Delete this"
    end
  end
end
