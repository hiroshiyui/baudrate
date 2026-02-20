defmodule BaudrateWeb.Plugs.RateLimitTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Hammer.delete_buckets("login:127.0.0.1")
    Hammer.delete_buckets("totp:127.0.0.1")
    {:ok, conn: conn}
  end

  describe "login rate limiting" do
    test "allows requests under the limit", %{conn: conn} do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)

      conn = post(conn, "/auth/session", %{"token" => token})
      assert redirected_to(conn) == "/"
    end

    test "blocks requests over the limit", %{conn: conn} do
      # Exhaust the rate limit (10 per 5 minutes)
      for _ <- 1..11 do
        Hammer.check_rate("login:127.0.0.1", 300_000, 10)
      end

      conn = post(conn, "/auth/session", %{"token" => "any"})
      assert conn.status == 429
      assert conn.resp_body =~ "Too many requests"
    end
  end

  describe "TOTP rate limiting" do
    test "blocks TOTP verify after too many attempts", %{conn: conn} do
      for _ <- 1..16 do
        Hammer.check_rate("totp:127.0.0.1", 300_000, 15)
      end

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: 1})
        |> post("/auth/totp-verify", %{"code" => "123456"})

      assert conn.status == 429
    end

    test "blocks TOTP enable after too many attempts", %{conn: conn} do
      for _ <- 1..16 do
        Hammer.check_rate("totp:127.0.0.1", 300_000, 15)
      end

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: 1})
        |> post("/auth/totp-enable", %{"code" => "123456"})

      assert conn.status == 429
    end
  end
end
