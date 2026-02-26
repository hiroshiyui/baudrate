defmodule BaudrateWeb.SecurityHeadersTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  describe "content-security-policy header" do
    test "is present in responses", %{conn: conn} do
      conn = get(conn, "/login")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src"
    end

    test "allows blob: in img-src for avatar crop preview", %{conn: conn} do
      conn = get(conn, "/login")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "img-src 'self' data: blob:"
      refute csp =~ "img-src 'self' data: blob: https:"
    end

    test "blocks plugins with object-src 'none'", %{conn: conn} do
      conn = get(conn, "/login")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "object-src 'none'"
    end

    test "allows blob: in connect-src for CropperJS", %{conn: conn} do
      conn = get(conn, "/login")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src 'self' blob: ws: wss:"
    end

    test "restricts script-src to self only", %{conn: conn} do
      conn = get(conn, "/login")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src 'self'"
      refute csp =~ "script-src 'self' 'unsafe-inline'"
    end

    test "denies frame embedding", %{conn: conn} do
      conn = get(conn, "/login")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'none'"
    end

    test "restricts form-action to self", %{conn: conn} do
      conn = get(conn, "/login")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "form-action 'self'"
    end
  end

  describe "referrer-policy header" do
    test "is set to strict-origin-when-cross-origin", %{conn: conn} do
      conn = get(conn, "/login")
      [policy] = get_resp_header(conn, "referrer-policy")
      assert policy == "strict-origin-when-cross-origin"
    end
  end
end
