defmodule BaudrateWeb.Plugs.CORSTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.Plugs.CORS

  defp call_plug(method) do
    conn =
      Plug.Test.conn(method, "/ap/site")
      |> CORS.call(CORS.init([]))

    conn
  end

  describe "call/2" do
    test "sets CORS headers on GET requests" do
      conn = call_plug(:get)

      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-methods") == ["GET, HEAD, OPTIONS"]
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-headers") == ["accept, content-type"]
      refute conn.halted
    end

    test "handles OPTIONS preflight with 204" do
      conn = call_plug(:options)

      assert conn.status == 204
      assert conn.halted
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end
end
