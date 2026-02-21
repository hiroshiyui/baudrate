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

    {:ok, invite} = Auth.generate_invite_code(admin.id)

    {:ok, lv, _html} = live(conn, "/admin/invites")

    html = lv |> element("button[phx-click=\"revoke\"][phx-value-id=\"#{invite.id}\"]") |> render_click()
    assert html =~ "Invite code revoked"
  end
end
