defmodule BaudrateWeb.UserInvitesLiveTest do
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

  test "authenticated user can access /invites", %{conn: conn} do
    user = setup_user("user") |> backdate_user(8)
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, "/invites")
    assert html =~ "My Invites"
  end

  test "unauthenticated user is redirected", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/invites")
  end

  test "user sees quota info", %{conn: conn} do
    user = setup_user("user") |> backdate_user(8)
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, "/invites")
    assert html =~ "5 of 5 invites remaining"
  end

  test "user can generate an invite code", %{conn: conn} do
    user = setup_user("user") |> backdate_user(8)
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, "/invites")

    html = lv |> element("button[phx-click=\"generate\"]") |> render_click()
    assert html =~ "Invite code generated"
    assert html =~ "4 of 5 invites remaining"
  end

  test "user can revoke their own code", %{conn: conn} do
    user = setup_user("user") |> backdate_user(8)
    conn = log_in_user(conn, user)

    {:ok, invite} = Auth.generate_invite_code(user)

    {:ok, lv, _html} = live(conn, "/invites")

    html =
      lv
      |> element("button[phx-click=\"revoke\"][phx-value-id=\"#{invite.id}\"]")
      |> render_click()

    assert html =~ "Invite code revoked"
  end

  test "quota-exceeded user sees disabled generate button", %{conn: conn} do
    user = setup_user("user") |> backdate_user(8)

    for _ <- 1..5 do
      {:ok, _} = Auth.generate_invite_code(user)
    end

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, "/invites")

    assert html =~ "0 of 5 invites remaining"
    assert html =~ "disabled"
  end

  test "new account sees disabled generate button", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, "/invites")
    assert html =~ "disabled"
  end

  test "active codes show copy and QR buttons", %{conn: conn} do
    user = setup_user("user") |> backdate_user(8)
    {:ok, invite} = Auth.generate_invite_code(user)

    conn = log_in_user(conn, user)
    {:ok, lv, html} = live(conn, "/invites")

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
