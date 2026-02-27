defmodule BaudrateWeb.ProfileLiveTest do
  use BaudrateWeb.ConnCase

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

  describe "locale management" do
    test "adds locale to preferences", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "add_locale", %{"locale" => "zh_TW"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert "zh_TW" in updated.preferred_locales
    end

    test "ignores duplicate locale", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["zh_TW"])
      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "add_locale", %{"locale" => "zh_TW"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.preferred_locales == ["zh_TW"]
    end

    test "removes locale", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["ja_JP", "zh_TW"])
      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "remove_locale", %{"locale" => "ja_JP"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.preferred_locales == ["zh_TW"]
    end

    test "moves locale up", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["ja_JP", "zh_TW"])
      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "move_locale_up", %{"locale" => "zh_TW"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.preferred_locales == ["zh_TW", "ja_JP"]
    end

    test "moves locale down", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["ja_JP", "zh_TW"])
      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "move_locale_down", %{"locale" => "ja_JP"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.preferred_locales == ["zh_TW", "ja_JP"]
    end
  end

  describe "unmute" do
    test "unmutes local user", %{conn: conn, user: user} do
      other = setup_user("user")
      {:ok, _mute} = Auth.mute_user(user, other)
      assert length(Auth.list_mutes(user)) == 1

      {:ok, lv, _html} = live(conn, "/profile")
      [mute] = Auth.list_mutes(user)
      html = render_click(lv, "unmute", %{"id" => to_string(mute.id)})

      assert html =~ "unmuted" or html =~ "Unmuted"
      assert Auth.list_mutes(user) == []
    end

    test "unmutes remote actor", %{conn: conn, user: user} do
      ap_id = "https://remote.example/users/someone"
      {:ok, _mute} = Auth.mute_remote_actor(user, ap_id)
      assert length(Auth.list_mutes(user)) == 1

      {:ok, lv, _html} = live(conn, "/profile")
      [mute] = Auth.list_mutes(user)
      html = render_click(lv, "unmute", %{"id" => to_string(mute.id)})

      assert html =~ "unmuted" or html =~ "Unmuted"
      assert Auth.list_mutes(user) == []
    end
  end

  describe "bio editing" do
    test "saves bio", %{conn: conn, user: _user} do
      {:ok, lv, _html} = live(conn, "/profile")

      lv
      |> form("form[phx-submit='save_bio']", %{bio: %{bio: "Hello, I'm a tester!"}})
      |> render_submit()

      html = render(lv)
      assert html =~ "Bio updated" or html =~ "已更新" or html =~ "更新しました"
    end

    test "validates max length", %{conn: conn, user: _user} do
      {:ok, lv, _html} = live(conn, "/profile")

      long_bio = String.duplicate("a", 501)

      html =
        lv
        |> form("form[phx-submit='save_bio']", %{bio: %{bio: long_bio}})
        |> render_change()

      assert html =~ "500"
    end
  end

  describe "DM access" do
    test "updates dm_access setting", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "update_dm_access", %{"dm_access" => "nobody"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.dm_access == "nobody"
    end
  end

  describe "notification preferences" do
    test "renders notification preference toggles", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")

      assert html =~ "Notification Preferences"
      assert html =~ "replied to your article"
      assert html =~ "mentioned you"
      assert html =~ "toggle"
    end

    test "toggles notification preference off", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "toggle_notification_pref", %{"type" => "mention"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.notification_preferences["mention"]["in_app"] == false
    end

    test "toggles notification preference back on", %{conn: conn, user: user} do
      {:ok, _} =
        Auth.update_notification_preferences(user, %{"mention" => %{"in_app" => false}})

      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "toggle_notification_pref", %{"type" => "mention"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.notification_preferences["mention"]["in_app"] == true
    end
  end

  describe "push notifications" do
    test "renders push manager hook", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ "push-manager"
      assert html =~ "PushManagerHook"
    end

    test "push_support event shows enable button", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")
      html = render_hook(lv, "push_support", %{"supported" => true, "subscribed" => false})
      assert html =~ "Enable Push"
    end

    test "push_subscribed shows disable button", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")
      render_hook(lv, "push_support", %{"supported" => true, "subscribed" => false})
      html = render_hook(lv, "push_subscribed", %{})
      assert html =~ "Disable Push"
    end

    test "push_unsubscribed shows enable button", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")
      render_hook(lv, "push_support", %{"supported" => true, "subscribed" => true})
      html = render_hook(lv, "push_unsubscribed", %{})
      assert html =~ "Enable Push"
    end

    test "push column visible only when subscribed", %{conn: conn} do
      {:ok, lv, html} = live(conn, "/profile")
      # Not subscribed: no Push column header in notification prefs table
      refute html =~ ~s(<th class="text-center">Push</th>)

      html = render_hook(lv, "push_support", %{"supported" => true, "subscribed" => true})
      assert html =~ ~s(<th class="text-center">Push</th>)
    end

    test "toggle_web_push_pref updates preferences", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")
      render_hook(lv, "push_support", %{"supported" => true, "subscribed" => true})
      render_click(lv, "toggle_web_push_pref", %{"type" => "mention"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.notification_preferences["mention"]["web_push"] == false
    end

    test "push_permission_denied shows flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")
      html = render_hook(lv, "push_permission_denied", %{})
      assert html =~ "denied"
    end

    test "push_subscribe_error shows flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")
      html = render_hook(lv, "push_subscribe_error", %{})
      assert html =~ "Failed to enable push notifications"
    end
  end

  describe "remove avatar" do
    test "removes user avatar", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_avatar(user, "test-avatar-id")
      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "remove_avatar")

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.avatar_id == nil
    end
  end
end
