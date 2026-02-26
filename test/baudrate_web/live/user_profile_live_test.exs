defmodule BaudrateWeb.UserProfileLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Federation
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  test "renders JSON-LD with foaf:Person and DC meta", %{conn: conn} do
    user = setup_user("user")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")

    assert html =~ "application/ld+json"
    assert html =~ "foaf:Person"
    assert html =~ "DC.title"
  end

  test "renders profile for valid user", %{conn: conn} do
    user = setup_user("user")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ user.username
    assert html =~ "Articles"
    assert html =~ "Comments"
  end

  test "redirects for nonexistent user", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/users/doesnotexist999")
  end

  test "redirects for banned user", %{conn: conn} do
    admin = setup_user("admin")
    user = setup_user("user")
    {:ok, _, _} = Auth.ban_user(user, admin.id, "test")

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/users/#{user.username}")
  end

  test "shows article and comment counts", %{conn: conn} do
    user = setup_user("user")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ "0"
  end

  test "mute event as guest is a no-op", %{conn: conn} do
    user = setup_user("user")

    {:ok, lv, _html} = live(conn, "/users/#{user.username}")

    # Simulate crafted websocket message — guest has no current_user
    assert render_hook(lv, :mute_user, %{})
    assert render_hook(lv, :unmute_user, %{})
  end

  test "displays bio on user profile page", %{conn: conn} do
    user = setup_user("user")
    {:ok, _updated} = Auth.update_bio(user, "This is my bio text")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ "Bio"
    assert html =~ "This is my bio text"
  end

  test "linkifies hashtags in bio display", %{conn: conn} do
    user = setup_user("user")
    {:ok, _updated} = Auth.update_bio(user, "I love #elixir")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ ~s(href="/tags/elixir")
    assert html =~ "#elixir"
  end

  test "displays signature on user profile page", %{conn: conn} do
    user = setup_user("user")
    {:ok, _updated} = Auth.update_signature(user, "My **profile** signature")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ "Signature"
    assert html =~ "profile"
  end

  describe "follow button" do
    test "shows follow button on other user's profile", %{conn: conn} do
      current_user = setup_user("user")
      profile_user = setup_user("user")
      conn = log_in_user(conn, current_user)

      {:ok, _lv, html} = live(conn, "/users/#{profile_user.username}")
      assert html =~ "Follow"
    end

    test "no follow button on own profile", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      refute html =~ "follow_user"
    end

    test "follow event creates local follow", %{conn: conn} do
      current_user = setup_user("user")
      profile_user = setup_user("user")
      conn = log_in_user(conn, current_user)

      {:ok, lv, _html} = live(conn, "/users/#{profile_user.username}")

      html = lv |> element(~s(button[phx-click="follow_user"])) |> render_click()
      assert html =~ "Followed successfully"
      assert Federation.local_follows?(current_user.id, profile_user.id)
    end

    test "unfollow event removes local follow", %{conn: conn} do
      current_user = setup_user("user")
      profile_user = setup_user("user")
      {:ok, _} = Federation.create_local_follow(current_user, profile_user)
      conn = log_in_user(conn, current_user)

      {:ok, lv, html} = live(conn, "/users/#{profile_user.username}")
      assert html =~ "Unfollow"

      html = lv |> element(~s(button[phx-click="unfollow_user"])) |> render_click()
      assert html =~ "Unfollowed successfully"
      refute Federation.local_follows?(current_user.id, profile_user.id)
    end

    test "guest users don't see follow button", %{conn: conn} do
      user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      refute html =~ "follow_user"
    end
  end
end
