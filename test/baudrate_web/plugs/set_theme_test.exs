defmodule BaudrateWeb.Plugs.SetThemeTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  test "assigns default themes when no settings exist", %{conn: conn} do
    conn = get(conn, "/")

    assert conn.assigns[:theme_light] == "light"
    assert conn.assigns[:theme_dark] == "dark"
  end

  test "assigns custom themes from settings", %{conn: conn} do
    Setup.set_setting("theme_light", "cupcake")
    Setup.set_setting("theme_dark", "dracula")

    conn = get(conn, "/")

    assert conn.assigns[:theme_light] == "cupcake"
    assert conn.assigns[:theme_dark] == "dracula"
  end
end
