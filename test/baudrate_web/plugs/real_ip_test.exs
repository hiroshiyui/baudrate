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

  describe "extract_peer_ip/1 (shared LiveView helper)" do
    defp fake_socket(connect_info) do
      %Phoenix.LiveView.Socket{private: %{connect_info: connect_info}}
    end

    setup do
      on_exit(fn -> Application.delete_env(:baudrate, RealIp) end)
    end

    test "returns IP from x-forwarded-for when header is configured" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          x_headers: [{"x-forwarded-for", "203.0.113.50, 10.0.0.1"}],
          peer_data: %{address: {127, 0, 0, 1}}
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "203.0.113.50"
    end

    test "returns single IP from x-forwarded-for" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          x_headers: [{"x-forwarded-for", "198.51.100.42"}],
          peer_data: %{address: {127, 0, 0, 1}}
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "198.51.100.42"
    end

    test "falls back to peer_data when no header configured" do
      Application.delete_env(:baudrate, RealIp)

      socket =
        fake_socket(%{
          x_headers: [{"x-forwarded-for", "203.0.113.50"}],
          peer_data: %{address: {192, 168, 1, 1}}
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "192.168.1.1"
    end

    test "falls back to peer_data when header configured but absent in x_headers" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          x_headers: [],
          peer_data: %{address: {10, 0, 0, 5}}
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "10.0.0.5"
    end

    test "falls back to peer_data when x_headers is nil" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          peer_data: %{address: {10, 0, 0, 5}}
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "10.0.0.5"
    end

    test "returns unknown when neither source is available" do
      Application.delete_env(:baudrate, RealIp)

      socket = fake_socket(%{})

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "unknown"
    end
  end
end
