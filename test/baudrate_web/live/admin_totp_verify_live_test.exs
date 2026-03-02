defmodule BaudrateWeb.AdminTotpVerifyLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  # Helper to create an admin with TOTP enabled (but no sudo session)
  defp setup_totp_admin do
    admin = setup_user("admin")
    secret = Auth.generate_totp_secret()
    {:ok, admin} = Auth.enable_totp(admin, secret)
    Repo.preload(admin, :role)
  end

  describe "GET /admin/verify" do
    test "admin can view verification page with form", %{conn: conn} do
      admin = setup_totp_admin()
      conn = log_in_user(conn, admin)

      {:ok, _lv, html} = live(conn, "/admin/verify")
      assert html =~ "Admin Verification Required"
      assert html =~ "admin-totp-code-form"
      assert html =~ "admin-totp-verify-form"
      assert html =~ ~s(inputmode="numeric")
      assert html =~ ~s(autocomplete="one-time-code")
    end

    test "non-admin is redirected away", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/verify")
    end

    test "moderator is redirected away", %{conn: conn} do
      moderator = setup_user("moderator")
      conn = log_in_user(conn, moderator)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/verify")
    end

    test "guest is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin/verify")
    end

    test "return_to passed through to hidden field", %{conn: conn} do
      admin = setup_totp_admin()
      conn = log_in_user(conn, admin)

      {:ok, _lv, html} = live(conn, "/admin/verify?return_to=/admin/users")
      assert html =~ ~s(value="/admin/users")
    end

    test "malicious return_to sanitized to /admin/settings", %{conn: conn} do
      admin = setup_totp_admin()
      conn = log_in_user(conn, admin)

      {:ok, _lv, html} = live(conn, "/admin/verify?return_to=https://evil.com")
      assert html =~ ~s(value="/admin/settings")
    end

    test "return_to with path traversal sanitized", %{conn: conn} do
      admin = setup_totp_admin()
      conn = log_in_user(conn, admin)

      {:ok, _lv, html} = live(conn, "/admin/verify?return_to=/admin/../secret")
      assert html =~ ~s(value="/admin/settings")
    end

    test "form rejects non-numeric code", %{conn: conn} do
      admin = setup_totp_admin()
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/verify")

      html =
        lv
        |> form("#admin-totp-code-form", admin_totp: %{code: "abcdef"})
        |> render_submit()

      assert html =~ "Please enter a 6-digit code"
    end

    test "form rejects short code", %{conn: conn} do
      admin = setup_totp_admin()
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/verify")

      html =
        lv
        |> form("#admin-totp-code-form", admin_totp: %{code: "123"})
        |> render_submit()

      assert html =~ "Please enter a 6-digit code"
    end

    test "valid code triggers phx-trigger-action", %{conn: conn} do
      admin = setup_totp_admin()
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/verify")

      html =
        lv
        |> form("#admin-totp-code-form", admin_totp: %{code: "123456"})
        |> render_submit()

      assert html =~ ~s(phx-trigger-action)
      assert html =~ ~s(value="123456")
    end
  end

  describe "admin sudo mode enforcement" do
    test "admin without TOTP verification is redirected to /admin/verify", %{conn: conn} do
      admin = setup_totp_admin()
      # Use log_in_user (not log_in_admin) — no admin_totp_verified_at
      conn = log_in_user(conn, admin)

      assert {:error, {:redirect, %{to: "/admin/verify" <> _}}} =
               live(conn, "/admin/settings")
    end

    test "admin with recent verification accesses admin pages", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, "/admin/settings")
      assert html =~ "Admin Settings"
    end

    test "moderator accesses /admin/moderation without TOTP re-verification", %{conn: conn} do
      moderator = setup_user("moderator")
      conn = log_in_user(conn, moderator)

      {:ok, _lv, html} = live(conn, "/admin/moderation")
      assert html =~ "Moderation"
    end

    test "admin without TOTP enabled is redirected to profile", %{conn: conn} do
      admin = setup_user("admin")
      # admin has no TOTP configured by default
      refute admin.totp_enabled

      conn = log_in_user(conn, admin)

      assert {:error, {:redirect, %{to: "/profile"}}} = live(conn, "/admin/settings")
    end
  end
end
