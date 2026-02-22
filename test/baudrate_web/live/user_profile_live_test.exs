defmodule BaudrateWeb.UserProfileLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
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
    {:ok, _} = Auth.ban_user(user, admin.id, "test")

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/users/#{user.username}")
  end

  test "shows article and comment counts", %{conn: conn} do
    user = setup_user("user")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ "0"
  end

  test "displays signature on user profile page", %{conn: conn} do
    user = setup_user("user")
    {:ok, _updated} = Auth.update_signature(user, "My **profile** signature")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ "Signature"
    assert html =~ "profile"
  end
end
