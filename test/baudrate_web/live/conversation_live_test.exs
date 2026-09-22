defmodule BaudrateWeb.ConversationLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
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
      assert {:error, {:redirect, %{to: "/login" <> _}}} =
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
      # The registered hook name; "ScrollBottom" was never registered.
      assert has_element?(view, ~s(#message-list[phx-hook="ScrollBottomHook"]))
    end

    test "a long conversation shows its newest messages and loads older ones on request",
         %{conn: conn, user: user, other: other} do
      {:ok, conv} = Messaging.find_or_create_conversation(user, other)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Baudrate.Repo.insert_all(
        Baudrate.Messaging.DirectMessage,
        for n <- 1..105 do
          %{
            conversation_id: conv.id,
            sender_user_id: other.id,
            body: "history-#{n}-end",
            inserted_at: DateTime.add(now, n - 200, :second),
            updated_at: now
          }
        end
      )

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, "/messages/#{conv.id}")

      assert html =~ "history-105-end"
      refute html =~ "history-5-end"
      assert has_element?(view, "#conversation-load-older-button")

      html = view |> element("#conversation-load-older-button") |> render_click()

      assert html =~ "history-1-end"
      assert html =~ "history-105-end"
      refute has_element?(view, "#conversation-load-older-button")
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
      |> form("#conversation-compose-form", message: %{body: "Hello there!"})
      |> render_submit()

      assert render(view) =~ "Hello there!"
    end

    test "ignores empty messages", %{conn: conn, user: user, other: other} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/new?to=#{other.username}")

      view
      |> form("#conversation-compose-form", message: %{body: "  "})
      |> render_submit()

      # Should not crash, no message added (match DaisyUI chat bubble class, not hero icon names)
      refute render(view) =~ ~s(class="chat-bubble)
    end

    test "compose form keeps a stable id after sending", %{conn: conn, user: user, other: other} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/new?to=#{other.username}")

      assert has_element?(view, "form#conversation-compose-form")

      view
      |> form("#conversation-compose-form", message: %{body: "Draft"})
      |> render_change()

      view
      |> form("#conversation-compose-form", message: %{body: "Draft"})
      |> render_submit()

      assert has_element?(view, "form#conversation-compose-form")
      assert has_element?(view, "#conversation-compose-input[value='']")
    end

    test "the log covers the messages, not the load-older control", %{
      conn: conn,
      user: user,
      other: other
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/new?to=#{other.username}")

      # `role="log"` implies `aria-live="polite"` with `aria-relevant="additions"`.
      # While it wrapped the whole list, "Load older messages" prepended a page
      # of history into the live region and every message was read out — the
      # `CLAUDE.md` rule about never making a whole list live.
      assert has_element?(view, "#message-list[aria-label='Messages']")
      assert has_element?(view, "#message-log[role='log']")
      refute has_element?(view, "#message-list[role='log']")

      # The control and the status node sit outside the log.
      assert has_element?(view, "#conversation-history-status[role='status']")
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
        |> form("#conversation-recipient-form",
          search: %{query: String.slice(other.username, 0, 5)}
        )
        |> render_change()

      assert html =~ other.username
      assert has_element?(view, "#conversation-search-results-status[role='status']")
      refute has_element?(view, "[role='listbox']")
      refute has_element?(view, "[role='option']")
    end

    test "clicking a result navigates to /messages/new?to=username", %{
      conn: conn,
      user: user,
      other: other
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/new")

      view
      |> form("#conversation-recipient-form", search: %{query: other.username})
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
        |> form("#conversation-recipient-form", search: %{query: user.username})
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

  describe "safety controls" do
    setup do
      BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})
      :ok
    end

    test "a received message can be reported, one's own cannot",
         %{conn: conn, user: user, other: other} do
      {:ok, conv} = Messaging.find_or_create_conversation(user, other)
      {:ok, mine} = Messaging.create_message(conv, user, %{body: "Hello"})
      {:ok, theirs} = Messaging.create_message(conv, other, %{body: "Go away"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/#{conv.id}")

      refute has_element?(view, "#message-report-#{mine.id}")
      refute has_element?(view, "#conversation-actions-menu")

      view |> element("#message-report-#{theirs.id}") |> render_click()
      assert has_element?(view, "#report-modal-title", "Report Message")

      view
      |> form("#report-modal form", %{"reason" => "Rude", "category" => "spam"})
      |> render_submit()

      assert [report] = Baudrate.Moderation.list_reports(status: "open")
      assert report.message_body == "Go away"
      assert report.reported_user_id == other.id
    end

    test "a remote participant can be muted, blocked and unblocked from the header",
         %{conn: conn, user: user} do
      uid = System.unique_integer([:positive])

      actor =
        %Baudrate.Federation.RemoteActor{}
        |> Baudrate.Federation.RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/dm-#{uid}",
          username: "dm_#{uid}",
          domain: "remote.example",
          public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
          inbox: "https://remote.example/users/dm-#{uid}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Baudrate.Repo.insert!()

      {:ok, message} =
        Messaging.receive_remote_dm(user, actor, %{
          body: "Hi",
          body_html: "<p>Hi</p>",
          ap_id: "https://remote.example/dms/#{uid}"
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/#{message.conversation_id}")

      view |> element("#conversation-mute-actor") |> render_click()
      assert Baudrate.Auth.muted?(user, actor.ap_id)
      assert has_element?(view, "#conversation-unmute-actor")

      view |> element("#conversation-block-actor") |> render_click()
      assert Baudrate.Auth.blocked?(user, actor.ap_id)
      assert has_element?(view, "#conversation-unblock-actor")
      assert_push_event(view, "focus", %{id: "conversation-actions-menu-toggle"})

      view |> element("#conversation-unblock-actor") |> render_click()
      refute Baudrate.Auth.blocked?(user, actor.ap_id)

      view |> element("#conversation-report-actor") |> render_click()

      view
      |> form("#report-modal form", %{"reason" => "Spam", "category" => "spam"})
      |> render_submit()

      assert [%{remote_actor_id: id}] = Baudrate.Moderation.list_reports(status: "open")
      assert id == actor.id
    end
  end

  describe "a new account" do
    # ADR 0064: a new account messages only people who follow it, who wrote
    # to it first, or staff — and is told so, never shown a bare refusal.
    setup do
      Baudrate.Repo.insert!(%Setting{key: "new_account_days", value: "3"})
      Baudrate.Repo.insert!(%Setting{key: "new_account_posts", value: "3"})
      :ok
    end

    test "cannot open a conversation with a stranger, and is told why", %{
      conn: conn,
      user: user,
      other: other
    } do
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/messages", flash: %{"error" => message}}}} =
               live(conn, "/messages/new?to=#{other.username}")

      assert message =~ "New accounts can send direct messages only to people who follow them"
    end

    test "can answer someone who wrote first", %{conn: conn, user: user} do
      staff = setup_user("moderator")
      {:ok, conv} = Messaging.find_or_create_conversation(staff, user)
      {:ok, _} = Messaging.create_message(conv, staff, %{body: "Welcome aboard."})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/#{conv.id}")

      view
      |> form("#conversation-compose-form", message: %{body: "Thank you!"})
      |> render_submit()

      assert render(view) =~ "Thank you!"
    end

    test "a refused send says why", %{conn: conn, user: user, other: other} do
      # The conversation was started before the limits were switched on.
      assert {2, _} =
               Baudrate.Repo.delete_all(
                 from(s in Setting, where: s.key in ~w(new_account_days new_account_posts))
               )

      {:ok, conv} = Messaging.find_or_create_conversation(user, other)
      {:ok, _} = Messaging.create_message(conv, user, %{body: "Old message"})
      Baudrate.Repo.insert!(%Setting{key: "new_account_days", value: "3"})
      Baudrate.Repo.insert!(%Setting{key: "new_account_posts", value: "3"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/messages/#{conv.id}")

      html =
        view
        |> form("#conversation-compose-form", message: %{body: "Hello again"})
        |> render_submit()

      assert html =~ "New accounts can send direct messages only"
    end
  end
end
