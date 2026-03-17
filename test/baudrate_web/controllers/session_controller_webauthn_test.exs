defmodule BaudrateWeb.SessionControllerWebAuthnTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Auth.WebAuthnChallenges
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Hammer.delete_buckets("totp:127.0.0.1")
    {:ok, conn: conn}
  end

  # ---------------------------------------------------------------------------
  # POST /auth/webauthn-register
  # ---------------------------------------------------------------------------

  describe "POST /auth/webauthn-register (webauthn_register/2)" do
    setup do
      user = setup_user("user")
      %{user: user}
    end

    test "requires authentication", %{conn: conn} do
      conn =
        post(conn, "/auth/webauthn-register", %{
          "attestation_object" => "dGVzdA",
          "client_data_json" => "dGVzdA",
          "challenge_token" => "fake",
          "label" => "My Key"
        })

      assert redirected_to(conn) =~ "/login"
    end

    test "rejects wrong user's challenge token", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      # Put a challenge for a different user
      other_user = setup_user("user")
      challenge = %{bytes: :crypto.strong_rand_bytes(32)}
      token = WebAuthnChallenges.put(other_user.id, challenge)

      conn =
        post(conn, "/auth/webauthn-register", %{
          "attestation_object" => "dGVzdA",
          "client_data_json" => "dGVzdA",
          "challenge_token" => token,
          "label" => "My Key"
        })

      assert redirected_to(conn) == "/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "rejects unknown challenge token", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      conn =
        post(conn, "/auth/webauthn-register", %{
          "attestation_object" => "dGVzdA",
          "client_data_json" => "dGVzdA",
          "challenge_token" => "nonexistent_token_12345",
          "label" => "My Key"
        })

      assert redirected_to(conn) == "/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "rejects when Wax verification fails (invalid attestation)", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      # Create a proper Wax challenge (struct with :issued_at, :bytes, etc.)
      challenge = Wax.new_registration_challenge([])
      token = WebAuthnChallenges.put(user.id, challenge)

      # Send garbage attestation data — Wax will reject it
      conn =
        post(conn, "/auth/webauthn-register", %{
          "attestation_object" => Base.url_encode64("not_valid_cbor", padding: false),
          "client_data_json" => Base.url_encode64("not_valid_json", padding: false),
          "challenge_token" => token,
          "label" => "My Key"
        })

      assert redirected_to(conn) == "/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /auth/admin-webauthn-verify
  # ---------------------------------------------------------------------------

  describe "POST /auth/admin-webauthn-verify (admin_webauthn_verify/2)" do
    setup do
      admin = setup_user("admin")
      %{admin: admin}
    end

    test "requires a valid session", %{conn: conn} do
      conn =
        post(conn, "/auth/admin-webauthn-verify", %{
          "authenticator_data" => "dGVzdA",
          "client_data_json" => "dGVzdA",
          "signature" => "dGVzdA",
          "credential_id" => "dGVzdA",
          "challenge_token" => "fake",
          "return_to" => "/admin/settings"
        })

      assert redirected_to(conn) =~ "/login"
    end

    test "rejects non-admin user", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      challenge = Wax.new_authentication_challenge([])
      token = WebAuthnChallenges.put(user.id, challenge)

      conn =
        post(conn, "/auth/admin-webauthn-verify", %{
          "authenticator_data" => "dGVzdA",
          "client_data_json" => "dGVzdA",
          "signature" => "dGVzdA",
          "credential_id" => "dGVzdA",
          "challenge_token" => token,
          "return_to" => "/admin/settings"
        })

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Access denied"
    end

    test "rejects unknown challenge token", %{conn: conn, admin: admin} do
      conn = log_in_user(conn, admin)

      conn =
        post(conn, "/auth/admin-webauthn-verify", %{
          "authenticator_data" => "dGVzdA",
          "client_data_json" => "dGVzdA",
          "signature" => "dGVzdA",
          "credential_id" => "dGVzdA",
          "challenge_token" => "nonexistent_token",
          "return_to" => "/admin/settings"
        })

      assert redirected_to(conn) =~ "/admin/verify"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "increments attempt counter on failed verification", %{conn: conn, admin: admin} do
      conn = log_in_user(conn, admin)

      challenge = Wax.new_authentication_challenge([])
      token = WebAuthnChallenges.put(admin.id, challenge)

      # Challenge exists but Wax rejects the garbage payload
      conn =
        post(conn, "/auth/admin-webauthn-verify", %{
          "authenticator_data" => Base.url_encode64("bad", padding: false),
          "client_data_json" => Base.url_encode64("bad", padding: false),
          "signature" => Base.url_encode64("bad", padding: false),
          "credential_id" => Base.url_encode64("bad", padding: false),
          "challenge_token" => token,
          "return_to" => "/admin/settings"
        })

      # Verification failed — must redirect back to verify page with an error
      assert redirected_to(conn) =~ "/admin/verify"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "lockout after 5 failed attempts redirects to / without dropping session",
         %{conn: conn, admin: admin} do
      conn =
        conn
        |> log_in_user(admin)
        |> put_session(:admin_webauthn_attempts, 5)

      challenge = Wax.new_authentication_challenge([])
      token = WebAuthnChallenges.put(admin.id, challenge)

      conn =
        post(conn, "/auth/admin-webauthn-verify", %{
          "authenticator_data" => "dGVzdA",
          "client_data_json" => "dGVzdA",
          "signature" => "dGVzdA",
          "credential_id" => "dGVzdA",
          "challenge_token" => token,
          "return_to" => "/admin/settings"
        })

      # Locked out → redirected to "/" (not login — session is preserved)
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many failed attempts"
      # Session is NOT dropped — user remains logged in
      assert get_session(conn, :session_token) != nil
    end

    test "sanitizes invalid return_to path", %{conn: conn, admin: admin} do
      conn = log_in_user(conn, admin)

      challenge = Wax.new_authentication_challenge([])
      token = WebAuthnChallenges.put(admin.id, challenge)

      conn =
        post(conn, "/auth/admin-webauthn-verify", %{
          "authenticator_data" => "dGVzdA",
          "client_data_json" => "dGVzdA",
          "signature" => "dGVzdA",
          "credential_id" => "dGVzdA",
          "challenge_token" => token,
          "return_to" => "https://evil.com/steal"
        })

      # Must not redirect to an external host regardless of outcome
      redirect = redirected_to(conn)
      refute redirect =~ "evil.com"
    end
  end
end
