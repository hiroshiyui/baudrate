defmodule BaudrateWeb.ProfileNotificationsLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "notification preferences" do
    test "renders notification preference toggles", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile/notifications")

      assert html =~ "Notification Preferences"
      assert html =~ "replied to your article"
      assert html =~ "mentioned you"
      assert html =~ "toggle"
    end

    test "toggles notification preference off", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile/notifications")
      render_click(lv, "toggle_notification_pref", %{"type" => "mention"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.notification_preferences["mention"]["in_app"] == false
    end

    test "every rendered toggle can actually be switched off", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile/notifications")

      for type <- Baudrate.Notification.Notification.configurable_types() do
        assert has_element?(lv, "#profile-notification-in-app-#{type}")
        html = render_click(lv, "toggle_notification_pref", %{"type" => type})
        refute html =~ "Failed to update notification preferences."
      end

      updated = Repo.get!(Baudrate.Setup.User, user.id)

      for type <- ~w(comment_liked article_boosted comment_boosted) do
        assert updated.notification_preferences[type]["in_app"] == false
      end
    end

    test "account security notices are not offered as toggles", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile/notifications")

      for type <- Baudrate.Notification.Notification.security_types() do
        refute has_element?(lv, "#profile-notification-in-app-#{type}")
      end
    end

    test "toggles notification preference back on", %{conn: conn, user: user} do
      {:ok, _} =
        Auth.update_notification_preferences(user, %{"mention" => %{"in_app" => false}})

      {:ok, lv, _html} = live(conn, "/profile/notifications")
      render_click(lv, "toggle_notification_pref", %{"type" => "mention"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.notification_preferences["mention"]["in_app"] == true
    end

    # A direct message makes no notification row (ADR 0071); its one
    # preference is whether to push, stored under a push-only key.
    test "direct-message pushes can be switched off", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile/notifications")
      html = render_click(lv, "toggle_web_push_pref", %{"type" => "direct_message"})

      refute html =~ "Failed to update notification preferences."
      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.notification_preferences["direct_message"] == %{"web_push" => false}
    end

    # The in-app toggle used to replace the type's settings wholesale, so it
    # silently switched push back on for anyone who had turned it off.
    test "toggling in-app keeps the web-push choice", %{conn: conn, user: user} do
      {:ok, _} =
        Auth.update_notification_preferences(user, %{"mention" => %{"web_push" => false}})

      {:ok, lv, _html} = live(conn, "/profile/notifications")
      render_click(lv, "toggle_notification_pref", %{"type" => "mention"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)

      assert updated.notification_preferences["mention"] == %{
               "in_app" => false,
               "web_push" => false
             }
    end
  end

  describe "push notifications" do
    test "renders push manager hook", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile/notifications")
      assert html =~ "push-manager"
      assert html =~ "PushManagerHook"
    end

    test "push_support event shows enable button", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile/notifications")
      html = render_hook(lv, "push_support", %{"supported" => true, "subscribed" => false})
      assert html =~ "Enable Push"
    end

    test "push_subscribed shows disable button", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile/notifications")
      render_hook(lv, "push_support", %{"supported" => true, "subscribed" => false})
      html = render_hook(lv, "push_subscribed", %{})
      assert html =~ "Disable Push"
    end

    test "push_unsubscribed shows enable button", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile/notifications")
      render_hook(lv, "push_support", %{"supported" => true, "subscribed" => true})
      html = render_hook(lv, "push_unsubscribed", %{})
      assert html =~ "Enable Push"
    end

    test "push column visible only when subscribed", %{conn: conn} do
      {:ok, lv, html} = live(conn, "/profile/notifications")
      # Not subscribed: no Push column header in notification prefs table
      refute html =~ ~s(<th class="text-center">Push</th>)

      html = render_hook(lv, "push_support", %{"supported" => true, "subscribed" => true})
      assert html =~ ~s(<th class="text-center">Push</th>)
    end

    test "toggle_web_push_pref updates preferences", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile/notifications")
      render_hook(lv, "push_support", %{"supported" => true, "subscribed" => true})
      render_click(lv, "toggle_web_push_pref", %{"type" => "mention"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.notification_preferences["mention"]["web_push"] == false
    end

    test "push_permission_denied shows flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile/notifications")
      html = render_hook(lv, "push_permission_denied", %{})
      assert html =~ "denied"
    end

    test "push_subscribe_error shows flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile/notifications")
      html = render_hook(lv, "push_subscribe_error", %{})
      assert html =~ "Failed to enable push notifications"
    end
  end
end
