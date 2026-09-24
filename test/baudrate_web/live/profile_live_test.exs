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

  describe "remove avatar" do
    test "removes user avatar", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_avatar(user, Baudrate.Avatar.generate_avatar_id())
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

      {:ok, lv, _html} = live(conn, "/profile/notifications")
      assert has_element?(lv, "h2#push-notifications-heading")

      {:ok, lv, _html} = live(conn, "/profile/privacy")

      assert has_element?(
               lv,
               ~s(section#profile-muted-users[aria-labelledby="profile-muted-users-heading"])
             )

      assert has_element?(lv, "h2#profile-muted-users-heading", "Muted Users")
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
