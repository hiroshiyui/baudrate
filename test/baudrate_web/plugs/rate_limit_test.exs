defmodule BaudrateWeb.Plugs.RateLimitTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting
  alias BaudrateWeb.RateLimiter.Sandbox

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  describe "login rate limiting" do
    test "allows requests under the limit", %{conn: conn} do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)

      Sandbox.set_fun(fn _bucket, _scale, _limit ->
        {:allow, 1}
      end)

      conn = post(conn, "/auth/session", %{"token" => token})
      assert redirected_to(conn) == "/"
    end

    test "blocks requests over the limit", %{conn: conn} do
      Sandbox.set_fun(fn _bucket, _scale, _limit ->
        {:deny, 10}
      end)

      conn = post(conn, "/auth/session", %{"token" => "any"})
      assert conn.status == 429
      assert conn.resp_body =~ "Too many requests"
    end
  end

  describe "TOTP rate limiting" do
    test "blocks TOTP verify after too many attempts", %{conn: conn} do
      Sandbox.set_fun(fn _bucket, _scale, _limit ->
        {:deny, 15}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: 1})
        |> post("/auth/totp-verify", %{"code" => "123456"})

      assert conn.status == 429
    end

    test "blocks TOTP enable after too many attempts", %{conn: conn} do
      Sandbox.set_fun(fn _bucket, _scale, _limit ->
        {:deny, 15}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: 1})
        |> post("/auth/totp-enable", %{"code" => "123456"})

      assert conn.status == 429
    end
  end

  describe "error path (fail-open)" do
    test "passes through on backend error", %{conn: conn} do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)

      Sandbox.set_fun(fn _bucket, _scale, _limit ->
        {:error, :backend_down}
      end)

      conn = post(conn, "/auth/session", %{"token" => token})
      # Should not be 429 — fail open
      refute conn.status == 429
    end
  end
end
