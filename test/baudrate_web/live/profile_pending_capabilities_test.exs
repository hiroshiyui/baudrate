defmodule BaudrateWeb.ProfilePendingCapabilitiesTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user", %{status: "pending"})
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  test "pending user can update bio", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, "/profile")

    lv
    |> form("#profile-bio-section form", bio: %{bio: "My new pending bio"})
    |> render_submit()

    assert Repo.get(Baudrate.Setup.User, user.id).bio == "My new pending bio"
  end

  test "pending user can update signature", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, "/profile")

    lv
    |> form("#profile-signature-section form", signature: %{signature: "My new pending signature"})
    |> render_submit()

    assert Repo.get(Baudrate.Setup.User, user.id).signature == "My new pending signature"
  end

  test "pending user can update display name", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, "/profile")

    lv
    |> form("#profile-display-name form", display_name: %{display_name: "New Display Name"})
    |> render_submit()

    assert Repo.get(Baudrate.Setup.User, user.id).display_name == "New Display Name"
  end

  test "pending user can update DM access", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, "/profile")

    lv
    |> element("select[name=\"dm_access\"]")
    |> render_change(%{"dm_access" => "followers"})

    assert Repo.get(Baudrate.Setup.User, user.id).dm_access == "followers"
  end

  test "pending user can update notification preferences", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, "/profile")

    lv
    |> element("input[phx-click=\"toggle_notification_pref\"][phx-value-type=\"mention\"]")
    |> render_click()

    prefs = Repo.get(Baudrate.Setup.User, user.id).notification_preferences
    assert get_in(prefs, ["mention", "in_app"]) == false
  end

  test "renders avatar upload form and hint for pending user", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/profile")
    assert html =~ "avatar-upload-form"
    assert html =~ "Change Avatar"
    assert html =~ "Your account is pending approval."
    assert html =~ "You can update your profile while you wait."
  end
end
