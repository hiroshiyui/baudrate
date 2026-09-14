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

    test "restricts img-src to self, blocking third-party hotlinking", %{conn: conn} do
      # Remote images and avatars are served through the local media proxy
      # (`Baudrate.Media.Proxy`), so no page needs to reach a third-party host
      # and no viewer's IP is disclosed to one.
      conn = get(conn, "/login")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "img-src 'self' data: blob:"
      refute csp =~ "img-src 'self' https:"
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

    test "allows the theme bootstrap inline script by its hash, and nothing else inline",
         %{conn: conn} do
      conn = get(conn, "/login")
      [csp] = get_resp_header(conn, "content-security-policy")

      # The script the page actually renders must hash to what the policy allows.
      [_, inline] = Regex.run(~r{<script>(.*?)</script>}s, html_response(conn, 200))
      hash = "'sha256-" <> Base.encode64(:crypto.hash(:sha256, inline)) <> "'"

      assert [_, script_src] = Regex.run(~r/script-src ([^;]*)/, csp)
      assert String.split(script_src) == ["'self'", hash]
    end

    test "allows YouTube embeds in frame-src", %{conn: conn} do
      conn = get(conn, "/login")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-src https://www.youtube-nocookie.com"
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
