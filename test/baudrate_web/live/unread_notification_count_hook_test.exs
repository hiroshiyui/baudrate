defmodule BaudrateWeb.UnreadNotificationCountHookTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Notification
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "unread notification badge in navbar" do
    test "shows badge when user has unread notifications", %{conn: conn, user: user} do
      other = setup_user("user")

      {:ok, _notif} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: other.id
        })

      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "badge badge-secondary badge-xs"
      assert html =~ "1"
    end

    test "does not show badge when no unread notifications", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")

      refute html =~ "badge badge-secondary badge-xs"
    end

    test "updates badge in real time when notification is created", %{conn: conn, user: user} do
      other = setup_user("user")

      {:ok, lv, html} = live(conn, "/")
      refute html =~ "badge badge-secondary badge-xs"

      # Create a notification (broadcasts :notification_created)
      {:ok, _notif} =
        Notification.create_notification(%{
          type: "mention",
          user_id: user.id,
          actor_user_id: other.id
        })

      # The hook should pick up the :notification_created event and update the count
      html = render(lv)
      assert html =~ "badge badge-secondary badge-xs"
      assert html =~ "1"
    end

    test "updates badge when notification is marked read", %{conn: conn, user: user} do
      other = setup_user("user")

      {:ok, notif} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: other.id
        })

      {:ok, lv, html} = live(conn, "/")
      assert html =~ "badge badge-secondary badge-xs"

      # Mark as read (broadcasts :notification_read)
      Notification.mark_as_read(notif)

      html = render(lv)
      refute html =~ "badge badge-secondary badge-xs"
    end

    test "badge shows correct count for multiple unread notifications", %{
      conn: conn,
      user: user
    } do
      other = setup_user("user")

      for type <- ["reply_to_article", "mention", "new_follower"] do
        {:ok, _} =
          Notification.create_notification(%{
            type: type,
            user_id: user.id,
            actor_user_id: other.id
          })
      end

      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "badge badge-secondary badge-xs"
      assert html =~ "3"
    end

    test "badge appears on optional_auth pages when authenticated", %{conn: conn, user: user} do
      other = setup_user("user")

      {:ok, _notif} =
        Notification.create_notification(%{
          type: "article_liked",
          user_id: user.id,
          actor_user_id: other.id
        })

      # "/" uses optional_auth live_session
      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "badge badge-secondary badge-xs"
    end
  end
end
