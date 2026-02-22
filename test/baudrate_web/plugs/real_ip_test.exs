defmodule BaudrateWeb.Plugs.RealIpTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.Plugs.RealIp

  defp conn_with_ip(ip_tuple) do
    %Plug.Conn{remote_ip: ip_tuple}
  end

  defp put_header(conn, key, value) do
    %{conn | req_headers: [{key, value} | conn.req_headers]}
  end

  describe "call/2 with no config" do
    test "passes through unchanged when no header configured" do
      # Default config: no header
      Application.delete_env(:baudrate, RealIp)

      conn = conn_with_ip({10, 0, 0, 1})
      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {10, 0, 0, 1}
    end
  end

  describe "call/2 with x-forwarded-for header" do
    setup do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")
      on_exit(fn -> Application.delete_env(:baudrate, RealIp) end)
    end

    test "extracts first IP from x-forwarded-for" do
      conn =
        conn_with_ip({10, 0, 0, 1})
        |> put_header("x-forwarded-for", "203.0.113.50, 70.41.3.18, 150.172.238.178")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {203, 0, 113, 50}
    end

    test "handles single IP in header" do
      conn =
        conn_with_ip({10, 0, 0, 1})
        |> put_header("x-forwarded-for", "203.0.113.50")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {203, 0, 113, 50}
    end

    test "handles IPv6 address" do
      conn =
        conn_with_ip({10, 0, 0, 1})
        |> put_header("x-forwarded-for", "2001:db8::1")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
    end

    test "ignores unparseable IP and keeps original" do
      conn =
        conn_with_ip({10, 0, 0, 1})
        |> put_header("x-forwarded-for", "not-an-ip")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {10, 0, 0, 1}
    end

    test "keeps original IP when header is absent" do
      conn = conn_with_ip({10, 0, 0, 1})
      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {10, 0, 0, 1}
    end
  end
end
