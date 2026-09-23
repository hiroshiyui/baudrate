defmodule BaudrateWeb.ProfileAccountLiveTest do
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
      {:ok, lv, _html} = live(conn, "/profile/account")
      render_click(lv, "add_locale", %{"locale" => "zh_TW"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert "zh_TW" in updated.preferred_locales
    end

    test "ignores duplicate locale", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["zh_TW"])
      {:ok, lv, _html} = live(conn, "/profile/account")
      render_click(lv, "add_locale", %{"locale" => "zh_TW"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.preferred_locales == ["zh_TW"]
    end

    test "removes locale", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["ja_JP", "zh_TW"])
      {:ok, lv, _html} = live(conn, "/profile/account")
      render_click(lv, "remove_locale", %{"locale" => "ja_JP"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.preferred_locales == ["zh_TW"]
    end

    test "moves locale up", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["ja_JP", "zh_TW"])
      {:ok, lv, _html} = live(conn, "/profile/account")
      render_click(lv, "move_locale_up", %{"locale" => "zh_TW"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.preferred_locales == ["zh_TW", "ja_JP"]
    end

    test "moves locale down", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["ja_JP", "zh_TW"])
      {:ok, lv, _html} = live(conn, "/profile/account")
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
      {:ok, lv, _html} = live(conn, "/profile/account")

      refute sync_form(render_click(lv, "move_locale_up", %{"locale" => "en"})) =~
               "phx-trigger-action",
             "nothing moved, so there is nothing to sync"

      refute sync_form(render_click(lv, "add_locale", %{"locale" => "ja_JP"})) =~
               "phx-trigger-action",
             "ja_JP was appended below en, so what anyone reads is unchanged"

      form = sync_form(render_click(lv, "move_locale_up", %{"locale" => "ja_JP"}))

      assert form =~ "phx-trigger-action"
      assert form =~ ~s(value="ja_JP")
      assert form =~ ~s(name="return_to" value="/profile/account")
    end

    test "emptying the list syncs as 'automatic', not as a language", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["ja_JP"])
      {:ok, lv, _html} = live(conn, "/profile/account")

      form = sync_form(render_click(lv, "remove_locale", %{"locale" => "ja_JP"}))

      assert form =~ "phx-trigger-action"

      assert form =~ ~s(value="#{BaudrateWeb.Locale.auto()}"),
             "posting a language here would re-assert the one just removed"
    end

    test "a reorder below the head does not reload the page", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_preferred_locales(user, ["en", "ja_JP", "zh_TW"])
      {:ok, lv, _html} = live(conn, "/profile/account")

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

  describe "accessibility" do
    test "add language trigger has no redundant tabindex", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile/account")

      assert has_element?(lv, ~s(#profile-add-language[aria-haspopup="true"]))
      refute has_element?(lv, "#profile-add-language[tabindex]")
      refute has_element?(lv, "#profile-add-language-menu[tabindex]")
    end
  end
end
