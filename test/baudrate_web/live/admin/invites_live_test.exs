defmodule BaudrateWeb.Admin.InvitesLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  test "admin can view invites page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/invites")
    assert html =~ "Invite Codes"
  end

  test "non-admin is redirected away", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/invites")
  end

  test "admin can generate an invite code", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/invites")

    html = lv |> element("button[phx-click=\"generate\"]") |> render_click()
    assert html =~ "Invite code generated"
  end

  test "admin can revoke an invite code", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, invite} = Auth.generate_invite_code(admin)

    {:ok, lv, _html} = live(conn, "/admin/invites")

    html =
      lv
      |> element("button[phx-click=\"revoke\"][phx-value-id=\"#{invite.id}\"]")
      |> render_click()

    assert html =~ "Invite code revoked"
  end

  test "active codes show copy and QR buttons", %{conn: conn} do
    admin = setup_user("admin")
    {:ok, invite} = Auth.generate_invite_code(admin)

    conn = log_in_user(conn, admin)
    {:ok, lv, html} = live(conn, "/admin/invites")

    assert html =~ "CopyToClipboardHook"
    assert html =~ "data-copy-text"
    assert html =~ "/register?invite="
    assert html =~ "hero-qr-code"

    # Click QR button opens modal with QR image
    html =
      lv
      |> element("button[phx-click=\"show_qr_code\"][phx-value-code=\"#{invite.code}\"]")
      |> render_click()

    assert html =~ "data:image/svg+xml;base64,"
    assert html =~ "modal modal-open"

    # Close modal
    html = lv |> element("button[phx-click=\"close_qr_modal\"]") |> render_click()
    refute html =~ "modal modal-open"
  end
end
