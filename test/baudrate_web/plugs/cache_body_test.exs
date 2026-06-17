defmodule BaudrateWeb.Plugs.CacheBodyTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.Plugs.CacheBody

  defp call_plug(conn), do: CacheBody.call(conn, CacheBody.init([]))

  describe "call/2 normal body" do
    test "caches body in conn.assigns.raw_body" do
      body = Jason.encode!(%{"type" => "Create"})
      conn = Plug.Test.conn(:post, "/ap/inbox", body) |> call_plug()

      refute conn.halted
      assert conn.assigns.raw_body == body
    end

    test "does not halt connection" do
      conn = Plug.Test.conn(:post, "/ap/inbox", "{}") |> call_plug()

      refute conn.halted
    end

    test "handles empty body" do
      conn = Plug.Test.conn(:post, "/ap/inbox", "") |> call_plug()

      refute conn.halted
      assert conn.assigns.raw_body == ""
    end
  end

  describe "call/2 oversized body (413)" do
    test "rejects a pre-cached raw_body over the limit with 413" do
      # CacheBodyReader path: the body is already in conn.assigns.raw_body.
      oversized = String.duplicate("x", 262_145)

      conn =
        Plug.Test.conn(:post, "/ap/inbox", "")
        |> Plug.Conn.assign(:raw_body, oversized)
        |> call_plug()

      assert conn.halted
      assert conn.status == 413
    end

    test "413 response is JSON with an error message" do
      oversized = String.duplicate("x", 262_145)

      conn =
        Plug.Test.conn(:post, "/ap/inbox", "")
        |> Plug.Conn.assign(:raw_body, oversized)
        |> call_plug()

      assert conn.status == 413
      assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers
      assert Jason.decode!(conn.resp_body) == %{"error" => "Payload too large"}
    end
  end

  describe "call/2 with custom config" do
    setup do
      original = Application.get_env(:baudrate, Baudrate.Federation)

      on_exit(fn ->
        if original do
          Application.put_env(:baudrate, Baudrate.Federation, original)
        else
          Application.delete_env(:baudrate, Baudrate.Federation)
        end
      end)

      :ok
    end

    test "reads max_payload_size from config" do
      Application.put_env(:baudrate, Baudrate.Federation, max_payload_size: 100)

      # A small body under the limit should still work
      body = String.duplicate("x", 50)
      conn = Plug.Test.conn(:post, "/ap/inbox", body) |> call_plug()

      refute conn.halted
      assert conn.assigns.raw_body == body
    end

    test "uses default 262,144 when config not set" do
      Application.delete_env(:baudrate, Baudrate.Federation)

      body = String.duplicate("x", 1000)
      conn = Plug.Test.conn(:post, "/ap/inbox", body) |> call_plug()

      refute conn.halted
      assert conn.assigns.raw_body == body
    end

    test "rejects a streamed body exceeding the configured limit with 413" do
      # No pre-cached raw_body: the read_body path returns {:more, ...} when the
      # body exceeds the length option, which must halt with 413.
      Application.put_env(:baudrate, Baudrate.Federation, max_payload_size: 100)

      body = String.duplicate("x", 500)
      conn = Plug.Test.conn(:post, "/ap/inbox", body) |> call_plug()

      assert conn.halted
      assert conn.status == 413
      assert Jason.decode!(conn.resp_body) == %{"error" => "Payload too large"}
    end
  end
end
