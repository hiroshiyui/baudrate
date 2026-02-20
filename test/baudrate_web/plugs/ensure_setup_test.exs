defmodule BaudrateWeb.Plugs.EnsureSetupTest do
  use BaudrateWeb.ConnCase, async: true

  alias Baudrate.Setup.Setting

  describe "when setup is not completed" do
    test "redirects / to /setup", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == "/setup"
    end

    test "allows access to /setup", %{conn: conn} do
      conn = get(conn, ~p"/setup")
      assert html_response(conn, 200)
    end
  end

  describe "when setup is completed" do
    setup %{conn: conn} do
      Baudrate.Repo.insert!(%Setting{key: "setup_completed", value: "true"})
      %{conn: conn}
    end

    test "redirects unauthenticated user to /login", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == "/login"
    end

    test "redirects /setup to /", %{conn: conn} do
      conn = get(conn, ~p"/setup")
      assert redirected_to(conn) == "/"
    end
  end
end
