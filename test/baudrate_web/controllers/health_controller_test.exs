defmodule BaudrateWeb.HealthControllerTest do
  use BaudrateWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns 200 with ok status when database is reachable", %{conn: conn} do
      conn = get(conn, "/health")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end
  end
end
