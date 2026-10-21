defmodule BaudrateWeb.MeControllerTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  describe "GET /me" do
    test "redirects a member to their own profile, uncached", %{conn: conn} do
      user = setup_user("user")

      conn = conn |> log_in_user(user) |> get("/me")

      # 302, never 301: the target depends on who is asking.
      assert redirected_to(conn, 302) == "/users/#{user.username}"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "sends a guest to sign in", %{conn: conn} do
      assert redirected_to(get(conn, "/me"), 302) == "/login"
    end

    test "sends a banned account's session to sign in", %{conn: conn} do
      admin = setup_user("admin")
      user = setup_user("user")
      conn = log_in_user(conn, user)
      {:ok, _, _} = Baudrate.Auth.ban_user(user, admin, "test")

      assert redirected_to(get(conn, "/me"), 302) == "/login"
    end
  end
end
