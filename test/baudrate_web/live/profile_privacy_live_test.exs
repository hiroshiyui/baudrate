defmodule BaudrateWeb.ProfilePrivacyLiveTest do
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

  describe "unmute" do
    test "unmutes local user", %{conn: conn, user: user} do
      other = setup_user("user")
      {:ok, _mute} = Auth.mute_user(user, other)
      assert length(Auth.list_mutes(user)) == 1

      {:ok, lv, _html} = live(conn, "/profile/privacy")
      [mute] = Auth.list_mutes(user)
      html = render_click(lv, "unmute", %{"id" => to_string(mute.id)})

      assert html =~ "unmuted" or html =~ "Unmuted"
      assert Auth.list_mutes(user) == []
    end

    test "unmutes remote actor", %{conn: conn, user: user} do
      ap_id = "https://remote.example/users/someone"
      {:ok, _mute} = Auth.mute_remote_actor(user, ap_id)
      assert length(Auth.list_mutes(user)) == 1

      {:ok, lv, _html} = live(conn, "/profile/privacy")
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

      {:ok, lv, _html} = live(conn, "/profile/privacy")

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
      {:ok, lv, _html} = live(conn, "/profile/privacy")
      assert has_element?(lv, "#profile-blocked-accounts-empty")
    end
  end

  describe "DM access" do
    test "updates dm_access setting", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile/privacy")
      render_click(lv, "update_dm_access", %{"dm_access" => "nobody"})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.dm_access == "nobody"
    end
  end
end
