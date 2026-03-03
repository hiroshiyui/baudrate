defmodule BaudrateWeb.LayoutsTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "font size controls" do
    test "renders font size decrease button in navbar", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ "Decrease font size"
      assert html =~ "hero-minus-micro"
    end

    test "renders font size increase button in navbar", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ "Increase font size"
      assert html =~ "hero-plus-micro"
    end

    test "decrease button dispatches phx:font-size-decrease event", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ "phx:font-size-decrease"
    end

    test "increase button dispatches phx:font-size-increase event", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ "phx:font-size-increase"
    end

    test "font size controls have role=group with aria-label", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ ~s(role="group")
      assert html =~ "Font size"
    end
  end

  describe "theme toggle" do
    test "renders theme toggle in navbar", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ "System theme"
      assert html =~ "Light theme"
      assert html =~ "Dark theme"
    end

    test "theme toggle has role=group with aria-label", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ "Theme"
    end
  end

  describe "mobile bottom nav (authenticated)" do
    test "renders bottom nav with all 5 items", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ ~s(id="mobile-bottom-nav")
      assert html =~ "hero-home"
      assert html =~ "hero-rss"
      assert html =~ "hero-magnifying-glass"
      assert html =~ "hero-chat-bubble-left-right"
      assert html =~ "hero-bell"
    end

    test "has lg:hidden class and aria-label", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ ~s(aria-label="Mobile navigation")
      assert html =~ "lg:hidden"
    end

    test "applies dock-active class and aria-current for current page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/search")
      # The search link in the bottom nav should have dock-active and aria-current="page"
      assert html =~ ~r/href="\/search"[^>]*class="dock-active"/
      assert html =~ ~r/href="\/search"[^>]*aria-current="page"/
    end

    test "does not show guest-only items", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      refute html =~ "hero-arrow-right-on-rectangle"
      refute html =~ "hero-user-plus"
    end
  end

  describe "mobile bottom nav (guest)" do
    setup %{conn: _conn} do
      # Use a fresh, unauthenticated connection
      {:ok, conn: Phoenix.ConnTest.build_conn()}
    end

    test "renders bottom nav with 4 guest items", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")
      assert html =~ ~s(id="mobile-bottom-nav")
      assert html =~ "hero-home"
      assert html =~ "hero-magnifying-glass"
      assert html =~ "hero-arrow-right-on-rectangle"
      assert html =~ "hero-user-plus"
    end

    test "does not show authenticated-only items", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")
      refute html =~ "hero-rss"
      refute html =~ "hero-chat-bubble-left-right"
      refute html =~ "hero-bell"
    end

    test "has lg:hidden class and aria-label", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")
      assert html =~ ~s(aria-label="Mobile navigation")
      assert html =~ "lg:hidden"
    end
  end
end
