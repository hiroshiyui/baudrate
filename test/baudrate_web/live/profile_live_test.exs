defmodule BaudrateWeb.ProfileLiveTest do
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

    # `SetLocale` reads a member's language from `session[:preferred_locales]`,
    # which is written at login and nowhere else, and a LiveView cannot write
    # the session. So a change here used to reach the database and stop: every
    # later full page load rendered its dead HTML — and `<html lang>` — in the
    # old language, on every load, until the member signed in again.
    #
    # The session write is a POST to `LocaleController`; what this page owes is
    # to submit it, and only when the *effective* locale actually moved.
    test "a change to the effective language posts the session write", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["en"])
      {:ok, lv, _html} = live(conn, "/profile")

      refute sync_form(render_click(lv, "move_locale_up", %{"locale" => "en"})) =~
               "phx-trigger-action",
             "nothing moved, so there is nothing to sync"

      refute sync_form(render_click(lv, "add_locale", %{"locale" => "ja_JP"})) =~
               "phx-trigger-action",
             "ja_JP was appended below en, so what anyone reads is unchanged"

      form = sync_form(render_click(lv, "move_locale_up", %{"locale" => "ja_JP"}))

      assert form =~ "phx-trigger-action"
      assert form =~ ~s(value="ja_JP")
      assert form =~ ~s(name="return_to" value="/profile")
    end

    test "emptying the list syncs as 'automatic', not as a language", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["ja_JP"])
      {:ok, lv, _html} = live(conn, "/profile")

      form = sync_form(render_click(lv, "remove_locale", %{"locale" => "ja_JP"}))

      assert form =~ "phx-trigger-action"

      assert form =~ ~s(value="#{BaudrateWeb.Locale.auto()}"),
             "posting a language here would re-assert the one just removed"
    end

    test "a reorder below the head does not reload the page", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["en", "ja_JP", "zh_TW"])
      {:ok, lv, _html} = live(conn, "/profile")

      form = sync_form(render_click(lv, "move_locale_up", %{"locale" => "zh_TW"}))

      refute form =~ "phx-trigger-action",
             "the account changed but the rendered language did not, so a " <>
               "full page reload here would be gratuitous"
    end

    # The hidden form's own markup, isolated so a `phx-trigger-action`
    # belonging to some other form on the page cannot answer for it.
    defp sync_form(html) do
      [_, rest] = String.split(html, ~s(id="locale-sync-form"), parts: 2)
      rest |> String.split("</form>", parts: 2) |> List.first()
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

  describe "blocked accounts" do
    test "lists local and remote blocks and unblocks them", %{conn: conn, user: user} do
      other = setup_user("user")
      uid = System.unique_integer([:positive])

      actor =
        %Baudrate.Federation.RemoteActor{}
        |> Baudrate.Federation.RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/pb-#{uid}",
          username: "pb_#{uid}",
          domain: "remote.example",
          public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
          inbox: "https://remote.example/users/pb-#{uid}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert!()

      {:ok, local_block} = Auth.block_user(user, other)
      {:ok, remote_block} = Auth.block_remote_actor(user, actor.ap_id)
      {:ok, unknown_block} = Auth.block_remote_actor(user, "https://gone.example/users/x")

      {:ok, lv, _html} = live(conn, "/profile")

      assert has_element?(lv, "#blocked-account-#{local_block.id}", other.username)
      assert has_element?(lv, "#blocked-account-#{remote_block.id}", "@pb_#{uid}@remote.example")

      assert has_element?(
               lv,
               "#blocked-account-#{unknown_block.id}",
               "https://gone.example/users/x"
             )

      assert has_element?(
               lv,
               ~s(#blocked-account-unblock-#{remote_block.id}[aria-label="Unblock @pb_#{uid}@remote.example"])
             )

      lv |> element("#blocked-account-unblock-#{local_block.id}") |> render_click()
      refute Auth.blocked?(user, other)
      assert_push_event(lv, "focus", %{id: "profile-blocked-accounts-heading"})

      lv |> element("#blocked-account-unblock-#{remote_block.id}") |> render_click()
      refute Auth.blocked?(user, actor.ap_id)
      refute has_element?(lv, "#blocked-account-#{remote_block.id}")
    end

    test "shows an empty state", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")
      assert has_element?(lv, "#profile-blocked-accounts-empty")
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

    test "every rendered toggle can actually be switched off", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")

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
      {:ok, lv, _html} = live(conn, "/profile")

      for type <- Baudrate.Notification.Notification.security_types() do
        refute has_element?(lv, "#profile-notification-in-app-#{type}")
      end
    end

    test "toggles notification preference back on", %{conn: conn, user: user} do
      {:ok, _} =
        Auth.update_notification_preferences(user, %{"mention" => %{"in_app" => false}})

      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "toggle_notification_pref", %{"type" => "mention"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.notification_preferences["mention"]["in_app"] == true
    end

    # A direct message makes no notification row (ADR 0071); its one
    # preference is whether to push, stored under a push-only key.
    test "direct-message pushes can be switched off", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")
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

      {:ok, lv, _html} = live(conn, "/profile")
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

  describe "accessibility" do
    test "display name, bio and signature inputs have associated labels", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")

      assert has_element?(lv, "#profile-display-name label", "Display Name")
      assert has_element?(lv, "#profile-display-name label input#display_name_display_name")

      assert has_element?(lv, ~s(#profile-bio-section label[for="bio_bio"]), "Bio")
      assert has_element?(lv, "#profile-bio-section textarea#bio_bio")

      assert has_element?(
               lv,
               ~s(#profile-signature-section label[for="signature_signature"]),
               "Signature"
             )

      assert has_element?(lv, "#profile-signature-section textarea#signature_signature")
    end

    test "section headings are h2 elements", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")

      assert has_element?(lv, "h2#crop-modal-title")
      assert has_element?(lv, "h2#push-notifications-heading")

      assert has_element?(
               lv,
               ~s(section#profile-muted-users[aria-labelledby="profile-muted-users-heading"])
             )

      assert has_element?(lv, "h2#profile-muted-users-heading", "Muted Users")
    end

    test "add language trigger has no redundant tabindex", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")

      assert has_element?(lv, ~s(#profile-add-language[aria-haspopup="true"]))
      refute has_element?(lv, "#profile-add-language[tabindex]")
      refute has_element?(lv, "#profile-add-language-menu[tabindex]")
    end
  end

  describe "a sanctioned member" do
    # Every one of these handlers used to hand the refusal atom to `to_form`,
    # which crashed the page; the member is told why instead (ADR 0029).
    setup %{user: user} do
      {:ok, _} =
        Auth.issue_sanction(setup_user("admin"), user, "silence",
          reason: "Cooling off",
          expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
        )

      :ok
    end

    test "saving a display name, bio or signature says why it was refused", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")

      for {form, params} <- [
            {"#profile-display-name-form", %{display_name: %{display_name: "New name"}}},
            {"#profile-bio-form", %{bio: %{bio: "New bio"}}},
            {"#profile-signature-form", %{signature: %{signature: "New signature"}}}
          ] do
        lv |> form(form, params) |> render_submit()

        # The page-wide notice already names the silence, so look at the flash.
        assert has_element?(lv, "#flash-error", "Your account is silenced and cannot post.")
        assert has_element?(lv, "#flash-error", "Cooling off")
      end
    end

    test "a refused avatar removal leaves the avatar it still shows", %{conn: conn, user: user} do
      # The files used to be deleted before the refused update, leaving the
      # account pointing at an avatar that no longer existed.
      scratch = Path.join(System.tmp_dir!(), "avatar-#{System.unique_integer([:positive])}.png")

      File.write!(
        scratch,
        Image.new!(64, 64, color: :white) |> Image.write!(:memory, suffix: ".png")
      )

      on_exit(fn -> File.rm(scratch) end)

      {:ok, avatar_id} =
        Baudrate.Avatar.process_upload(scratch, %{
          "x" => 0.0,
          "y" => 0.0,
          "width" => 1.0,
          "height" => 1.0
        })

      Repo.update_all(
        from(u in Baudrate.Setup.User, where: u.id == ^user.id),
        set: [avatar_id: avatar_id]
      )

      on_exit(fn -> Baudrate.Avatar.delete_avatar(avatar_id) end)
      BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})

      {:ok, lv, _html} = live(conn, "/profile")
      render_click(lv, "remove_avatar", %{})

      assert has_element?(lv, "#flash-error", "Your account is silenced and cannot post.")
      assert Repo.reload(user).avatar_id == avatar_id

      assert File.exists?(
               Application.app_dir(:baudrate, "priv/static/uploads/avatars/#{avatar_id}/48.webp")
             )
    end

    test "saving profile fields says why it was refused", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")

      render_submit(lv, "save_profile_fields", %{
        "profile_fields" => %{"0" => %{"name" => "Site", "value" => "example"}}
      })

      assert has_element?(lv, "#flash-error", "Your account is silenced and cannot post.")
    end
  end

  describe "a new account's signature" do
    test "cannot gain a link, and the member is told why", %{conn: conn} do
      Repo.insert!(%Setting{key: "new_account_days", value: "3"})
      Repo.insert!(%Setting{key: "new_account_posts", value: "3"})
      {:ok, lv, _html} = live(conn, "/profile")

      lv
      |> form("#profile-signature-form",
        signature: %{signature: "My [blog](https://blog.example/)"}
      )
      |> render_submit()

      assert has_element?(
               lv,
               "#flash-error",
               "New accounts cannot add links or images to their signature"
             )
    end
  end
end
