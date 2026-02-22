defmodule BaudrateWeb.Plugs.RequireAPContentTypeTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.Plugs.RequireAPContentType

  defp build_conn(content_type) do
    conn = Plug.Test.conn(:post, "/ap/inbox")

    if content_type do
      Plug.Conn.put_req_header(conn, "content-type", content_type)
    else
      conn
    end
  end

  describe "call/2" do
    test "passes application/activity+json" do
      conn = build_conn("application/activity+json")
      result = RequireAPContentType.call(conn, RequireAPContentType.init([]))
      refute result.halted
    end

    test "passes application/ld+json" do
      conn = build_conn("application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"")
      result = RequireAPContentType.call(conn, RequireAPContentType.init([]))
      refute result.halted
    end

    test "passes application/json" do
      conn = build_conn("application/json")
      result = RequireAPContentType.call(conn, RequireAPContentType.init([]))
      refute result.halted
    end

    test "passes application/json with charset" do
      conn = build_conn("application/json; charset=utf-8")
      result = RequireAPContentType.call(conn, RequireAPContentType.init([]))
      refute result.halted
    end

    test "rejects text/html" do
      conn = build_conn("text/html")
      result = RequireAPContentType.call(conn, RequireAPContentType.init([]))
      assert result.halted
      assert result.status == 415
    end

    test "rejects multipart/form-data" do
      conn = build_conn("multipart/form-data")
      result = RequireAPContentType.call(conn, RequireAPContentType.init([]))
      assert result.halted
      assert result.status == 415
    end

    test "rejects missing content-type" do
      conn = build_conn(nil)
      result = RequireAPContentType.call(conn, RequireAPContentType.init([]))
      assert result.halted
      assert result.status == 415
    end

    test "is case-insensitive" do
      conn = build_conn("Application/Activity+JSON")
      result = RequireAPContentType.call(conn, RequireAPContentType.init([]))
      refute result.halted
    end
  end
end
