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

  test "admin can generate invite code for another user", %{conn: conn} do
    admin = setup_user("admin")
    user = setup_user("user")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/invites")

    # Search for the user
    lv
    |> element("form[phx-change=\"search_users\"]")
    |> render_change(%{search: %{query: user.username}})

    # Generate code for user
    html =
      lv
      |> element("form[phx-submit=\"generate_for_user\"]")
      |> render_submit(%{user_id: user.id})

    assert html =~ "Invite code generated for"
    assert html =~ user.username
  end

  test "generated-for-user code shows target user as Created By", %{conn: conn} do
    admin = setup_user("admin")
    user = setup_user("user")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/invites")

    # Search and generate
    lv
    |> element("form[phx-change=\"search_users\"]")
    |> render_change(%{search: %{query: user.username}})

    html =
      lv
      |> element("form[phx-submit=\"generate_for_user\"]")
      |> render_submit(%{user_id: user.id})

    # The table should show the target user's name in the Created By column
    assert html =~ user.username
  end
end
