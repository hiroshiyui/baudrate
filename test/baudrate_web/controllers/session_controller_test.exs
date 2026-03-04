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

      assert redirected_to(conn) == "/profile/recovery-codes"
      assert get_session(conn, :session_token) != nil
      assert get_session(conn, :refresh_token) != nil
      assert is_nil(get_session(conn, :user_id))
      assert is_nil(get_session(conn, :totp_setup_secret))
      assert is_list(get_session(conn, :recovery_codes))
      assert length(get_session(conn, :recovery_codes)) == 10

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
        |> Plug.Test.init_test_session(%{
          user_id: user.id,
          totp_setup_secret: secret,
          totp_attempts: 5
        })
        |> post("/auth/totp-enable", %{"code" => "000000"})

      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many failed attempts"
    end
  end

  describe "POST /auth/totp-reset" do
    test "valid token with mode :reset disables TOTP and redirects to setup", %{conn: conn} do
      user = setup_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, user} = Auth.enable_totp(user, secret)
      assert user.totp_enabled

      token =
        Phoenix.Token.sign(BaudrateWeb.Endpoint, "totp_reset", %{user_id: user.id, mode: :reset})

      conn = post(conn, "/auth/totp-reset", %{"token" => token})
      assert redirected_to(conn) == "/totp/setup"
      assert get_session(conn, :totp_setup_secret) != nil
      assert get_session(conn, :user_id) == user.id

      updated_user = Auth.get_user(user.id)
      refute updated_user.totp_enabled
    end

    test "valid token with mode :enable redirects to setup without disabling TOTP", %{conn: conn} do
      user = setup_user("user")
      refute user.totp_enabled

      token =
        Phoenix.Token.sign(BaudrateWeb.Endpoint, "totp_reset", %{
          user_id: user.id,
          mode: :enable
        })

      conn = post(conn, "/auth/totp-reset", %{"token" => token})
      assert redirected_to(conn) == "/totp/setup"
      assert get_session(conn, :totp_setup_secret) != nil

      updated_user = Auth.get_user(user.id)
      refute updated_user.totp_enabled
    end

    test "invalid/expired token redirects to /profile with error", %{conn: conn} do
      conn = post(conn, "/auth/totp-reset", %{"token" => "bad_token"})
      assert redirected_to(conn) == "/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid or expired token"
    end

    test "token for nonexistent user redirects to /login", %{conn: conn} do
      token =
        Phoenix.Token.sign(BaudrateWeb.Endpoint, "totp_reset", %{user_id: 0, mode: :reset})

      conn = post(conn, "/auth/totp-reset", %{"token" => token})
      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) != nil
    end
  end

  describe "POST /auth/recovery-verify" do
    test "valid recovery code establishes session", %{conn: conn} do
      user = setup_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, user} = Auth.enable_totp(user, secret)
      [code | _] = Auth.generate_recovery_codes(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> post("/auth/recovery-verify", %{"code" => code})

      assert redirected_to(conn) == "/"
      assert get_session(conn, :session_token) != nil
      assert is_nil(get_session(conn, :user_id))
    end

    test "invalid recovery code shows error and increments attempts", %{conn: conn} do
      user = setup_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(user, secret)
      Auth.generate_recovery_codes(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> post("/auth/recovery-verify", %{"code" => "wrong-code-here"})

      assert redirected_to(conn) == "/totp/recovery"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid recovery code"
      assert get_session(conn, :totp_attempts) == 1
    end

    test "locks out at max attempts", %{conn: conn} do
      user = setup_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(user, secret)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id, totp_attempts: 5})
        |> post("/auth/recovery-verify", %{"code" => "any-code"})

      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many failed attempts"
    end

    test "redirects to /login without session", %{conn: conn} do
      conn = post(conn, "/auth/recovery-verify", %{"code" => "some-code"})
      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) != nil
    end
  end

  describe "POST /auth/ack-recovery-codes" do
    test "clears recovery_codes from session and redirects to /", %{conn: conn} do
      user = setup_user("user")

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Test.init_test_session(%{recovery_codes: ["code1", "code2"]})
        |> post("/auth/ack-recovery-codes")

      assert redirected_to(conn) == "/"
      assert is_nil(get_session(conn, :recovery_codes))
    end
  end

  describe "POST /auth/admin-totp-verify" do
    test "valid code sets timestamp and redirects to return_to", %{conn: conn} do
      admin = setup_user("admin")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(admin, secret)
      code = NimbleTOTP.verification_code(secret)

      conn =
        conn
        |> log_in_user(admin)
        |> post("/auth/admin-totp-verify", %{"code" => code, "return_to" => "/admin/users"})

      assert redirected_to(conn) == "/admin/users"
      assert is_integer(get_session(conn, :admin_totp_verified_at))
      assert is_nil(get_session(conn, :admin_totp_attempts))
    end

    test "invalid code shows error and increments attempts", %{conn: conn} do
      admin = setup_user("admin")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(admin, secret)

      conn =
        conn
        |> log_in_user(admin)
        |> post("/auth/admin-totp-verify", %{"code" => "000000", "return_to" => "/admin/users"})

      assert redirected_to(conn) =~ "/admin/verify"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid verification code"
      assert get_session(conn, :admin_totp_attempts) == 1
    end

    test "lockout after 5 failures redirects to /", %{conn: conn} do
      admin = setup_user("admin")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(admin, secret)

      conn =
        conn
        |> log_in_user(admin)
        |> put_session(:admin_totp_attempts, 5)
        |> post("/auth/admin-totp-verify", %{"code" => "000000", "return_to" => "/admin/users"})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many failed attempts"
      # Session is NOT dropped — user remains logged in
      assert get_session(conn, :session_token) != nil
      # Attempts counter is cleared after lockout
      assert is_nil(get_session(conn, :admin_totp_attempts))
    end

    test "non-admin gets access denied", %{conn: conn} do
      user = setup_user("user")

      conn =
        conn
        |> log_in_user(user)
        |> post("/auth/admin-totp-verify", %{"code" => "123456"})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Access denied"
    end

    test "malicious return_to falls back to /admin/settings", %{conn: conn} do
      admin = setup_user("admin")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(admin, secret)
      code = NimbleTOTP.verification_code(secret)

      conn =
        conn
        |> log_in_user(admin)
        |> post("/auth/admin-totp-verify", %{
          "code" => code,
          "return_to" => "https://evil.com"
        })

      assert redirected_to(conn) == "/admin/settings"
    end

    test "unauthenticated user redirects to login", %{conn: conn} do
      conn = post(conn, "/auth/admin-totp-verify", %{"code" => "123456"})
      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Session expired"
    end

    test "sanitizes admin return_to with null byte", %{conn: conn} do
      admin = setup_user("admin")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(admin, secret)
      code = NimbleTOTP.verification_code(secret)

      conn =
        conn
        |> log_in_user(admin)
        |> post("/auth/admin-totp-verify", %{
          "code" => code,
          "return_to" => "/admin/users\0malicious"
        })

      assert redirected_to(conn) == "/admin/settings"
    end

    test "sanitizes admin return_to with path traversal", %{conn: conn} do
      admin = setup_user("admin")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(admin, secret)
      code = NimbleTOTP.verification_code(secret)

      conn =
        conn
        |> log_in_user(admin)
        |> post("/auth/admin-totp-verify", %{
          "code" => code,
          "return_to" => "/admin/../../../etc/passwd"
        })

      assert redirected_to(conn) == "/admin/settings"
    end

    test "sanitizes admin return_to with double slashes", %{conn: conn} do
      admin = setup_user("admin")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(admin, secret)
      code = NimbleTOTP.verification_code(secret)

      conn =
        conn
        |> log_in_user(admin)
        |> post("/auth/admin-totp-verify", %{
          "code" => code,
          "return_to" => "/admin//evil.com"
        })

      assert redirected_to(conn) == "/admin/settings"
    end
  end

  describe "establish_session with :return_to" do
    test "redirects to stored return_to path after login", %{conn: conn} do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)

      conn =
        conn
        |> Plug.Test.init_test_session(%{return_to: "/articles/new?title=Shared"})
        |> post("/auth/session", %{"token" => token})

      assert redirected_to(conn) == "/articles/new?title=Shared"
      assert is_nil(get_session(conn, :return_to))
    end

    test "ignores return_to when explicit redirect_to is provided", %{conn: conn} do
      user = setup_user("admin")
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(user, secret)
      code = NimbleTOTP.verification_code(secret)

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          user_id: user.id,
          totp_setup_secret: secret,
          return_to: "/articles/new?title=Shared"
        })
        |> post("/auth/totp-enable", %{"code" => code})

      # totp_enable passes "/profile/recovery-codes" as redirect_to,
      # so return_to should be ignored
      assert redirected_to(conn) == "/profile/recovery-codes"
    end

    test "sanitizes malicious return_to with double slashes", %{conn: conn} do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)

      conn =
        conn
        |> Plug.Test.init_test_session(%{return_to: "//evil.com/steal"})
        |> post("/auth/session", %{"token" => token})

      assert redirected_to(conn) == "/"
    end

    test "sanitizes malicious return_to with path traversal", %{conn: conn} do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)

      conn =
        conn
        |> Plug.Test.init_test_session(%{return_to: "/foo/../../../etc/passwd"})
        |> post("/auth/session", %{"token" => token})

      assert redirected_to(conn) == "/"
    end

    test "sanitizes malicious return_to with @ authority", %{conn: conn} do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)

      conn =
        conn
        |> Plug.Test.init_test_session(%{return_to: "/redirect@evil.com"})
        |> post("/auth/session", %{"token" => token})

      assert redirected_to(conn) == "/"
    end

    test "falls back to / when return_to is nil", %{conn: conn} do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)
      conn = post(conn, "/auth/session", %{"token" => token})
      assert redirected_to(conn) == "/"
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
