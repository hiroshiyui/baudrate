defmodule BaudrateWeb.HandleRedirectControllerTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  describe "GET /@:handle" do
    test "redirects permanently to /users/:username for existing user", %{conn: conn} do
      user = setup_user("user")

      conn = get(conn, "/@#{user.username}")

      # 301: a permanent alias for the canonical profile path (ADR 0057).
      assert redirected_to(conn, 301) == "/users/#{user.username}"
    end

    test "returns 404 for nonexistent username", %{conn: conn} do
      conn = get(conn, "/@nonexistent-user-xyz")

      assert html_response(conn, 404)
    end

    test "returns 404 for a banned account, like the profile page does", %{conn: conn} do
      admin = setup_user("admin")
      user = setup_user("user")
      {:ok, _, _} = Baudrate.Auth.ban_user(user, admin, "test")

      conn = get(conn, "/@#{user.username}")

      assert html_response(conn, 404)
    end
  end
end
