defmodule BaudrateWeb.DataExportLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.{Auth, DataPortability, Repo}
  alias Baudrate.DataPortability.{DownloadNonces, ExportRequest}
  alias Baudrate.Setup.{Setting, User}
  alias BaudrateWeb.ExportController

  @password "Password123!x"

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  defp eligible(conn) do
    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)
    past = DateTime.utc_now() |> DateTime.add(-8 * 86_400) |> DateTime.truncate(:second)
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [totp_enabled_at: past])
    user = Repo.reload!(user)
    {log_in_user(conn, user), user, secret}
  end

  defp creds(secret), do: %{password: @password, code: totp_code(secret)}

  defp make_ready(request) do
    shift = DataPortability.ready_delay_seconds() + 60
    # A day later the user signs in with a new code; the request's code is used up (ADR 0024).
    forget_totp_use(request.user_id)

    Repo.update_all(from(r in ExportRequest, where: r.id == ^request.id),
      set: [
        requested_at: DateTime.add(request.requested_at, -shift),
        ready_at: DateTime.add(request.ready_at, -shift),
        expires_at: DateTime.add(request.expires_at, -shift)
      ]
    )

    Repo.reload!(request)
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login" <> _}}} = live(conn, "/profile/export")
  end

  test "without TOTP, explains why and links to TOTP setup", %{conn: conn} do
    user = setup_user("user")
    {:ok, lv, _html} = live(log_in_user(conn, user), "/profile/export")

    assert has_element?(lv, "#data-export-ineligible-reason", "Enable two-factor authentication")
    assert has_element?(lv, "#data-export-enable-totp[href='/profile/totp-reset']")
    refute has_element?(lv, "#data-export-request-form")
  end

  test "with TOTP enabled less than 7 days ago, shows the days left", %{conn: conn} do
    user = setup_user("user")
    {:ok, _} = Auth.enable_totp(user, Auth.generate_totp_secret())
    {:ok, lv, _html} = live(log_in_user(conn, user), "/profile/export")

    assert has_element?(lv, "#data-export-ineligible-reason", "You can export in 7 days")
  end

  test "requesting needs the password and TOTP code", %{conn: conn} do
    {conn, user, secret} = eligible(conn)
    {:ok, lv, _html} = live(conn, "/profile/export")

    html =
      lv
      |> form("#data-export-request-form", export_request: %{password: "wrong", code: "000000"})
      |> render_submit()

    assert html =~ "Invalid credentials"
    assert DataPortability.active_request(user.id) == nil

    lv
    |> form("#data-export-request-form", export_request: creds(secret))
    |> render_submit()

    assert has_element?(lv, "#data-export-active-heading", "Waiting")
    assert has_element?(lv, "#data-export-cancel")
    refute has_element?(lv, "#data-export-download-auth-form")
    assert [%{status: "pending"}] = DataPortability.list_export_history(user.id)
  end

  test "an active request shows a warning banner on every page", %{conn: conn} do
    {conn, user, secret} = eligible(conn)
    {:ok, _} = DataPortability.request_export(user, creds(secret), ip_address: "203.0.113.9")

    {:ok, lv, _html} = live(conn, "/profile")
    assert has_element?(lv, "#data-export-notice")
    assert has_element?(lv, "#data-export-notice-link[href='/profile/export']")

    {:ok, lv, _html} = live(conn, "/notifications")
    assert has_element?(lv, "#data-export-notice")
  end

  test "cancelling removes the request and the banner", %{conn: conn} do
    {conn, user, secret} = eligible(conn)

    {:ok, request} =
      DataPortability.request_export(user, creds(secret), ip_address: "203.0.113.9")

    {:ok, lv, _html} = live(conn, "/profile/export")

    lv |> element("#data-export-cancel") |> render_click()

    assert Repo.reload!(request).status == "cancelled"
    refute has_element?(lv, "#data-export-active")
    assert has_element?(lv, "#data-export-history-#{request.id}", "Cancelled")

    {:ok, lv, _html} = live(conn, "/profile")
    refute has_element?(lv, "#data-export-notice")
  end

  test "cancel and sign out everywhere else revokes other sessions", %{conn: conn} do
    {conn, user, secret} = eligible(conn)

    {:ok, request} =
      DataPortability.request_export(user, creds(secret), ip_address: "203.0.113.9")

    forget_totp_use(user)
    {:ok, other_token, _} = Auth.create_user_session(user.id)
    {:ok, lv, _html} = live(conn, "/profile/export")

    lv
    |> form("#data-export-cancel-sign-out-form", cancel_sign_out: creds(secret))
    |> render_submit()

    assert %{status: "cancelled", cancel_reason: "signed_out_everywhere"} = Repo.reload!(request)
    assert {:error, :not_found} = Auth.get_user_by_session_token(other_token)
  end

  test "downloading re-authenticates, then submits a single-use token for this session",
       %{conn: conn} do
    {conn, user, secret} = eligible(conn)

    {:ok, request} =
      DataPortability.request_export(user, creds(secret), ip_address: "203.0.113.9")

    make_ready(request)
    session_id = Auth.session_id_by_token(Plug.Conn.get_session(conn, :session_token))

    {:ok, lv, _html} = live(conn, "/profile/export")
    assert has_element?(lv, "#data-export-active-heading", "Ready to download")

    html =
      lv
      |> form("#data-export-download-auth-form", export_download: %{password: "wrong", code: "0"})
      |> render_submit()

    assert html =~ "Invalid credentials"
    refute has_element?(lv, "#data-export-download-form[phx-trigger-action]")

    lv
    |> form("#data-export-download-auth-form", export_download: creds(secret))
    |> render_submit()

    assert has_element?(lv, "#data-export-download-form[phx-trigger-action]")

    assert has_element?(
             lv,
             "#data-export-download-form[action='/exports/#{request.id}/download']"
           )

    token =
      lv
      |> element("#data-export-download-form input[name='token']")
      |> render()
      |> then(&Regex.run(~r/value="([^"]+)"/, &1))
      |> List.last()

    assert {:ok, claims} =
             Phoenix.Token.verify(BaudrateWeb.Endpoint, ExportController.token_salt(), token,
               max_age: 60
             )

    assert claims["request_id"] == request.id
    assert claims["user_id"] == user.id
    assert claims["session_id"] == session_id
    assert :ok = DownloadNonces.consume(claims["nonce"], user.id)
    assert :error = DownloadNonces.consume(claims["nonce"], user.id)

    # Authorizing does not count as a download.
    assert Repo.reload!(request).download_count == 0
  end
end
