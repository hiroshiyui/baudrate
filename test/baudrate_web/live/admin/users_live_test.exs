defmodule BaudrateWeb.Admin.UsersLiveTest do
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

  test "admin can view users page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/users")
    assert html =~ "User Management"
  end

  test "non-admin is redirected away", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/users")
  end

  test "admin can filter users by status", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/users")

    html = lv |> element("button[phx-click=\"filter\"][phx-value-status=\"active\"]") |> render_click()
    assert html =~ admin.username
  end

  test "admin can search users", %{conn: conn} do
    admin = setup_user("admin")
    user = setup_user("user")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/users")

    html = lv |> form("form[phx-change=\"search\"]", search: user.username) |> render_change()
    assert html =~ user.username
  end

  test "admin can ban a user", %{conn: conn} do
    admin = setup_user("admin")
    user = setup_user("user")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/users")

    # Open ban modal
    lv |> element("button[phx-click=\"show_ban_modal\"][phx-value-id=\"#{user.id}\"]") |> render_click()

    # Confirm ban
    html = lv |> element("button[phx-click=\"confirm_ban\"]") |> render_click()
    assert html =~ "User banned successfully"

    # Verify user is banned
    updated = Auth.get_user(user.id)
    assert updated.status == "banned"
  end

  test "admin can unban a user", %{conn: conn} do
    admin = setup_user("admin")
    user = setup_user("user")
    {:ok, _} = Auth.ban_user(user, admin.id, "test")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/users")

    # Filter to banned
    lv |> element("button[phx-click=\"filter\"][phx-value-status=\"banned\"]") |> render_click()

    html = lv |> element("button[phx-click=\"unban\"][phx-value-id=\"#{user.id}\"]") |> render_click()
    assert html =~ "User unbanned successfully"
  end

  test "admin can change user role", %{conn: conn} do
    admin = setup_user("admin")
    user = setup_user("user")
    conn = log_in_user(conn, admin)

    import Ecto.Query
    mod_role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "moderator"))

    {:ok, lv, _html} = live(conn, "/admin/users")

    html =
      lv
      |> form("form[phx-change=\"change_role\"][phx-value-id=\"#{user.id}\"]",
        role_id: mod_role.id
      )
      |> render_change()

    assert html =~ "User role updated successfully"
  end

  test "admin can approve a pending user", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    # Create a pending user
    import Ecto.Query
    alias Baudrate.Setup.{Role, User}
    role = Repo.one!(from(r in Role, where: r.name == "user"))

    {:ok, pending_user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "pending_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Ecto.Changeset.put_change(:status, "pending")
      |> Repo.insert()

    {:ok, lv, _html} = live(conn, "/admin/users")

    # Filter to pending
    lv |> element("button[phx-click=\"filter\"][phx-value-status=\"pending\"]") |> render_click()

    html = lv |> element("button[phx-click=\"approve\"][phx-value-id=\"#{pending_user.id}\"]") |> render_click()
    assert html =~ "User approved successfully"
  end

  test "pagination controls appear when users exceed per_page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    # Create enough users to exceed 1 page (per_page defaults to 20)
    for _i <- 1..21, do: setup_user("user")

    {:ok, _lv, html} = live(conn, "/admin/users")
    # Pagination should render with page buttons
    assert html =~ "join-item btn btn-sm btn-active"
    assert html =~ "»"
  end

  test "filter and pagination work together", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    # With only admin + 1 user, filtering to "active" should not show pagination
    _user = setup_user("user")

    {:ok, lv, _html} = live(conn, "/admin/users?status=active")

    html = render(lv)
    assert html =~ admin.username
    # Only 2 active users, should be on 1 page, no pagination
    refute html =~ "»"
  end
end
