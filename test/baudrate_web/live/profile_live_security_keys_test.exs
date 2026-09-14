defmodule BaudrateWeb.ProfileLiveSecurityKeysTest do
  @moduledoc """
  Security key (WebAuthn) management on `/profile` requires step-up
  re-authentication. A session cookie alone must not be able to enrol or
  remove a second factor (ADR 0022).
  """

  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Auth.LoginAttempt
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting
  alias BaudrateWeb.RateLimiter.Sandbox

  @password "Password123!x"

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp add_credential(user) do
    {:ok, cred} =
      Auth.create_webauthn_credential(user, %{
        credential_id: :crypto.strong_rand_bytes(32),
        public_key_cbor: CBOR.encode(%{1 => 2, -2 => :crypto.strong_rand_bytes(32)}),
        sign_count: 0,
        label: "Existing Key"
      })

    cred
  end

  defp reauth(lv, params) do
    lv
    |> form("#profile-security-reauth-form", security_reauth: params)
    |> render_submit()
  end

  describe "while locked" do
    test "shows the re-authentication form instead of key controls", %{conn: conn, user: user} do
      cred = add_credential(user)
      {:ok, lv, _html} = live(conn, "/profile")

      assert has_element?(lv, "#profile-security-reauth-form")
      assert has_element?(lv, "#security_reauth_password")
      refute has_element?(lv, "#security_reauth_code")
      refute has_element?(lv, "#profile-security-key-register")
      refute has_element?(lv, "#security-key-remove-#{cred.id}")
      # The key list itself stays visible.
      assert has_element?(lv, "#security-key-#{cred.id}")
    end

    test "begin_registration is refused and issues no challenge", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")

      html = render_click(lv, "begin_registration", %{})

      assert html =~ "Please confirm your identity before managing security keys."
      refute_push_event(lv, "webauthn_register", %{})
    end

    test "delete_webauthn_credential is refused", %{conn: conn, user: user} do
      cred = add_credential(user)
      {:ok, lv, _html} = live(conn, "/profile")

      html = render_click(lv, "delete_webauthn_credential", %{"id" => to_string(cred.id)})

      assert html =~ "Please confirm your identity before managing security keys."
      assert [%{id: id}] = Auth.list_webauthn_credentials(user)
      assert id == cred.id
    end
  end

  describe "re-authentication" do
    test "a wrong password keeps the section locked and is recorded", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")

      html = reauth(lv, %{password: "wrong"})

      assert html =~ "Invalid credentials"
      assert has_element?(lv, "#profile-security-reauth-form")
      refute has_element?(lv, "#profile-security-key-register")

      assert Repo.exists?(
               from(a in LoginAttempt, where: a.username == ^user.username and a.success == false)
             )
    end

    test "the correct password unlocks registration", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")

      reauth(lv, %{password: @password})

      refute has_element?(lv, "#profile-security-reauth-form")
      assert has_element?(lv, "#profile-security-key-register")

      render_click(lv, "begin_registration", %{})
      assert_push_event(lv, "webauthn_register", %{options: options})
      assert is_binary(options)
    end

    test "unlocking allows removing a key", %{conn: conn, user: user} do
      cred = add_credential(user)
      {:ok, lv, _html} = live(conn, "/profile")

      reauth(lv, %{password: @password})

      lv |> element("#security-key-remove-#{cred.id}") |> render_click()

      assert Auth.list_webauthn_credentials(user) == []
    end

    test "a malformed credential id does not crash the LiveView", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")
      reauth(lv, %{password: @password})

      html = render_click(lv, "delete_webauthn_credential", %{"id" => "not-a-number"})

      assert html =~ "Failed to remove security key."
      assert Process.alive?(lv.pid)
    end

    test "the unlock does not survive a reload", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")
      reauth(lv, %{password: @password})
      assert has_element?(lv, "#profile-security-key-register")

      {:ok, lv2, _html} = live(conn, "/profile")
      assert has_element?(lv2, "#profile-security-reauth-form")
      refute has_element?(lv2, "#profile-security-key-register")
    end

    test "an expired unlock is refused server-side", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")
      reauth(lv, %{password: @password})

      # Move the deadline into the past without waiting five minutes.
      :sys.replace_state(lv.pid, fn state ->
        put_in(
          state.socket.assigns.security_reauth_until,
          System.monotonic_time(:second) - 1
        )
      end)

      html = render_click(lv, "begin_registration", %{})

      assert html =~ "Please confirm your identity before managing security keys."
      refute_push_event(lv, "webauthn_register", %{})
      assert has_element?(lv, "#profile-security-reauth-form")
    end

    test "is refused when the per-user rate limit is exhausted", %{conn: conn} do
      Sandbox.set_fun(fn
        "reauth:" <> _, _scale, _limit -> {:deny, 900_000}
        _bucket, _scale, _limit -> {:allow, 1}
      end)

      {:ok, lv, _html} = live(conn, "/profile")
      html = reauth(lv, %{password: @password})

      assert html =~ "Too many attempts"
      refute has_element?(lv, "#profile-security-key-register")
    end
  end

  describe "sign out everywhere" do
    defp sign_out(lv, params) do
      lv
      |> form("#profile-sign-out-everywhere-form", sign_out: params)
      |> render_submit()
    end

    test "requires the password and keeps other sessions on failure", %{conn: conn, user: user} do
      {:ok, other_token, _} = Auth.create_user_session(user.id)
      {:ok, lv, _html} = live(conn, "/profile")

      html = sign_out(lv, %{password: "wrong"})

      assert html =~ "Invalid credentials"
      assert {:ok, _} = Auth.get_user_by_session_token(other_token)
    end

    test "signs out other sessions, keeps this one, and notifies", %{conn: conn, user: user} do
      {:ok, other_token, _} = Auth.create_user_session(user.id)
      this_token = Plug.Conn.get_session(conn, :session_token)
      {:ok, lv, _html} = live(conn, "/profile")

      html = sign_out(lv, %{password: @password})

      assert html =~ "Signed out 1 other session."
      assert {:error, :not_found} = Auth.get_user_by_session_token(other_token)
      assert {:ok, _} = Auth.get_user_by_session_token(this_token)

      assert Repo.exists?(
               from(n in Baudrate.Notification.Notification,
                 where: n.user_id == ^user.id and n.type == "signed_out_everywhere"
               )
             )
    end

    test "links to the password change page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")
      assert has_element?(lv, "#profile-password-change[href='/profile/password']")
    end
  end

  describe "accounts with TOTP enabled" do
    setup %{user: user} do
      secret = Auth.generate_totp_secret()
      {:ok, user} = Auth.enable_totp(user, secret)
      {:ok, user: user, secret: secret}
    end

    test "require the current code", %{conn: conn, secret: secret} do
      {:ok, lv, _html} = live(conn, "/profile")
      assert has_element?(lv, "#security_reauth_code")

      html = reauth(lv, %{password: @password, code: "000000"})
      assert html =~ "Invalid credentials"
      refute has_element?(lv, "#profile-security-key-register")

      reauth(lv, %{password: @password, code: NimbleTOTP.verification_code(secret)})
      assert has_element?(lv, "#profile-security-key-register")
    end
  end
end
