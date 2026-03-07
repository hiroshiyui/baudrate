defmodule BaudrateWeb.HandleRedirectControllerTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  describe "GET /@:handle" do
    test "redirects to /users/:username for existing user", %{conn: conn} do
      user = setup_user("user")

      conn = get(conn, "/@#{user.username}")

      assert redirected_to(conn) == "/users/#{user.username}"
    end

    test "returns 404 for nonexistent username", %{conn: conn} do
      conn = get(conn, "/@nonexistent-user-xyz")

      assert html_response(conn, 404)
    end
  end
end
