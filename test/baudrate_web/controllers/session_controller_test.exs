defmodule BaudrateWeb.SessionControllerTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Hammer.delete_buckets("login:127.0.0.1")
    Hammer.delete_buckets("totp:127.0.0.1")
    {:ok, conn: conn}
  end

  describe "POST /auth/session" do
    test "redirects to / for user role (no TOTP needed)", %{conn: conn} do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)
      conn = post(conn, "/auth/session", %{"token" => token})
      assert redirected_to(conn) == "/"
      assert get_session(conn, :session_token) != nil
      assert get_session(conn, :refresh_token) != nil
      assert is_nil(get_session(conn, :user_id))
    end

    test "redirects to /totp/setup for admin without TOTP", %{conn: conn} do
      user = setup_user("admin")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)
      conn = post(conn, "/auth/session", %{"token" => token})
      assert redirected_to(conn) == "/totp/setup"
      assert get_session(conn, :user_id) == user.id
      # Secret should be stored in session for TOTP setup
      assert get_session(conn, :totp_setup_secret) != nil
    end

    test "redirects to /totp/verify for user with TOTP enabled", %{conn: conn} do
      user = setup_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(user, secret)
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)
      conn = post(conn, "/auth/session", %{"token" => token})
      assert redirected_to(conn) == "/totp/verify"
    end

    test "rejects invalid token", %{conn: conn} do
      conn = post(conn, "/auth/session", %{"token" => "bad_token"})
      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid or expired token"
    end
  end

  describe "POST /auth/totp-verify" do
    test "verifies valid TOTP code", %{conn: conn} do
      user = setup_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(user, secret)
      code = NimbleTOTP.verification_code(secret)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> post("/auth/totp-verify", %{"code" => code})

      assert redirected_to(conn) == "/"
      assert get_session(conn, :session_token) != nil
      assert get_session(conn, :refresh_token) != nil
      assert is_nil(get_session(conn, :user_id))
    end

    test "rejects invalid TOTP code", %{conn: conn} do
      user = setup_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(user, secret)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> post("/auth/totp-verify", %{"code" => "000000"})

      assert redirected_to(conn) == "/totp/verify"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid verification code"
    end

    test "locks out after max failed attempts", %{conn: conn} do
      user = setup_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(user, secret)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id, totp_attempts: 5})
        |> post("/auth/totp-verify", %{"code" => "000000"})

      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many failed attempts"
    end

    test "redirects to /login without session", %{conn: conn} do
      conn = post(conn, "/auth/totp-verify", %{"code" => "123456"})
      assert redirected_to(conn) == "/login"
    end
  end

  describe "POST /auth/totp-enable" do
    test "enables TOTP with valid code (secret from session)", %{conn: conn} do
      user = setup_user("admin")
      secret = Auth.generate_totp_secret()
      code = NimbleTOTP.verification_code(secret)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id, totp_setup_secret: secret})
        |> post("/auth/totp-enable", %{"code" => code})

      assert redirected_to(conn) == "/"
      assert get_session(conn, :session_token) != nil
      assert get_session(conn, :refresh_token) != nil
      assert is_nil(get_session(conn, :user_id))
      assert is_nil(get_session(conn, :totp_setup_secret))

      updated_user = Auth.get_user(user.id)
      assert updated_user.totp_enabled == true
    end

    test "rejects invalid code during setup", %{conn: conn} do
      user = setup_user("admin")
      secret = Auth.generate_totp_secret()

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id, totp_setup_secret: secret})
        |> post("/auth/totp-enable", %{"code" => "000000"})

      assert redirected_to(conn) == "/totp/setup"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid verification code"
    end

    test "redirects to /login without session secret", %{conn: conn} do
      user = setup_user("admin")

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> post("/auth/totp-enable", %{"code" => "123456"})

      assert redirected_to(conn) == "/login"
    end

    test "locks out after max failed attempts", %{conn: conn} do
      user = setup_user("admin")
      secret = Auth.generate_totp_secret()

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id, totp_setup_secret: secret, totp_attempts: 5})
        |> post("/auth/totp-enable", %{"code" => "000000"})

      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many failed attempts"
    end
  end

  describe "DELETE /logout" do
    test "clears session and redirects to /login", %{conn: conn} do
      user = setup_user("user")

      conn =
        conn
        |> log_in_user(user)
        |> delete("/logout")

      assert redirected_to(conn) == "/login"
    end
  end
end
