defmodule BaudrateWeb.Plugs.AuthorizedFetchTest do
  use BaudrateWeb.ConnCase, async: false

  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  describe "authorized fetch plug" do
    test "passes through when setting is disabled", %{conn: conn} do
      Setup.set_setting("ap_authorized_fetch", "false")

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/ap/site")

      refute conn.halted
      assert conn.status in [200, 404]
    end

    test "returns 401 when enabled and no signature provided", %{conn: conn} do
      Setup.set_setting("ap_authorized_fetch", "true")

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/ap/site")

      assert conn.status == 401
    end

    test "allows WebFinger even when authorized fetch is enabled", %{conn: conn} do
      Setup.set_setting("ap_authorized_fetch", "true")

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/webfinger?resource=acct:nonexistent@localhost")

      # Should not be 401 — might be 404 or 400 but not blocked by auth
      refute conn.status == 401
    end

    test "allows NodeInfo even when authorized fetch is enabled", %{conn: conn} do
      Setup.set_setting("ap_authorized_fetch", "true")

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/nodeinfo")

      refute conn.status == 401
    end
  end
end
