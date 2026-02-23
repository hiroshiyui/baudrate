defmodule BaudrateWeb.ConversationsLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Messaging
  alias Baudrate.Setup.Setting

  setup do
    Baudrate.Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Baudrate.Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    user = setup_user("user")
    %{user: user}
  end

  describe "authenticated access" do
    test "redirects to login when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/messages")
    end

    test "renders empty state when no conversations", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages")
      assert render(view) =~ "No messages yet."
    end

    test "renders conversation list", %{conn: conn, user: user} do
      other = setup_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user, other)
      {:ok, _msg} = Messaging.create_message(conv, other, %{body: "Hello!"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages")
      assert render(view) =~ other.username
    end
  end
end
