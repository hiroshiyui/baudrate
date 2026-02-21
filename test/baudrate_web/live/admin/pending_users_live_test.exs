defmodule BaudrateWeb.Admin.PendingUsersLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  test "admin can view pending users page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/pending-users")
    assert html =~ "Pending Users"
    assert html =~ "No pending users"
  end

  test "admin sees pending users in the list", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, _pending_user} =
      Auth.register_user(%{
        "username" => "waitinguser",
        "password" => "SecurePass1!!",
        "password_confirmation" => "SecurePass1!!"
      })

    {:ok, _lv, html} = live(conn, "/admin/pending-users")
    assert html =~ "waitinguser"
    assert html =~ "Approve"
  end

  test "admin can approve a pending user", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, pending_user} =
      Auth.register_user(%{
        "username" => "approvaluser",
        "password" => "SecurePass1!!",
        "password_confirmation" => "SecurePass1!!"
      })

    {:ok, lv, _html} = live(conn, "/admin/pending-users")

    html =
      lv
      |> element("button", "Approve")
      |> render_click()

    assert html =~ "User approved successfully"
    refute html =~ "approvaluser"

    updated = Auth.get_user(pending_user.id)
    assert updated.status == "active"
  end

  test "non-admin is redirected away", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/pending-users")
  end
end
