defmodule BaudrateWeb.ProfileTimeZoneTest do
  @moduledoc """
  A member's own time zone (6E-1): chosen on `/profile/account`, applied to
  every timestamp they read, and never leaking to anyone else's page.
  """

  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Setup.set_setting("timezone", "Asia/Taipei")
    on_exit(fn -> BaudrateWeb.TimeZone.put(nil) end)

    user = setup_user("user")
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "choosing a zone" do
    test "saves a zone from the list and shows it at once", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile/account")

      lv
      |> form("#profile-time-zone-form", time_zone: %{time_zone: "America/New_York"})
      |> render_submit()

      assert Repo.reload!(user).time_zone == "America/New_York"
      assert has_element?(lv, "#profile-time-zone-current", "America/New_York")
      assert has_element?(lv, "#footer-time-zone", "America/New_York")
    end

    test "a re-render keeps the zone being picked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile/account")

      lv
      |> form("#profile-time-zone-form", time_zone: %{time_zone: "Europe/Berlin"})
      |> render_change()

      assert has_element?(
               lv,
               ~s(#profile-time-zone-select option[value="Europe/Berlin"][selected])
             )
    end

    test "the device's zone is saved when the site knows it", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile/account")

      lv
      |> element("#profile-time-zone-device")
      |> render_hook("use_device_time_zone", %{"zone" => "Asia/Tokyo"})

      assert Repo.reload!(user).time_zone == "Asia/Tokyo"
    end

    test "an unknown zone is refused, from the device or a crafted form", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, "/profile/account")

      lv
      |> element("#profile-time-zone-device")
      |> render_hook("use_device_time_zone", %{"zone" => "Mars/Olympus_Mons"})

      render_hook(lv, "save_time_zone", %{"time_zone" => %{"time_zone" => "Mars/Olympus_Mons"}})

      assert Repo.reload!(user).time_zone == nil
      assert {:error, _} = Auth.update_time_zone(user, "Mars/Olympus_Mons")
    end

    test "the site default clears it", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_time_zone(user, "Europe/Berlin")
      {:ok, lv, _html} = live(conn, "/profile/account")

      lv
      |> form("#profile-time-zone-form", time_zone: %{time_zone: ""})
      |> render_submit()

      assert Repo.reload!(user).time_zone == nil
    end
  end

  describe "whose zone a page is rendered in" do
    test "a member sees their own zone and a guest sees the site's", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_time_zone(user, "America/New_York")

      member_page = conn |> get("/profile/account") |> html_response(200)
      assert member_page =~ "America/New_York (UTC-0"

      guest_page = build_conn() |> get("/") |> html_response(200)
      assert guest_page =~ "Asia/Taipei (UTC+08:00)"
    end

    # One process can serve several keep-alive requests, from different
    # people. A zone left over from the member must not reach the next page.
    test "a request after a member's, in the same process, is in the site's zone", %{
      conn: conn,
      user: user
    } do
      {:ok, _} = Auth.update_time_zone(user, "America/New_York")
      conn |> get("/profile/account") |> html_response(200)
      assert BaudrateWeb.TimeZone.current() == "America/New_York"

      guest_page = build_conn() |> get("/") |> html_response(200)
      assert guest_page =~ "Asia/Taipei (UTC+08:00)"
      refute guest_page =~ "America/New_York"
    end

    test "time elements carry UTC whatever the viewer's zone", %{conn: conn, user: user} do
      {:ok, _} = Auth.update_time_zone(user, "America/New_York")

      {:ok, _lv, html} = live(conn, "/profile")
      refute html =~ ~r/datetime="\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"/
    end
  end
end
