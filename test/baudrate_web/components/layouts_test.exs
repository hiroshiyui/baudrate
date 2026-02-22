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
  end

  describe "theme toggle" do
    test "renders theme toggle in navbar", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ "System theme"
      assert html =~ "Light theme"
      assert html =~ "Dark theme"
    end
  end
end
