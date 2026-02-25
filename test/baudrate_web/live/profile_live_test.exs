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
