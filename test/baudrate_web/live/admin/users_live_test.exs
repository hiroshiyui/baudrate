defmodule BaudrateWeb.Admin.UsersLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Moderation
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

  # --- Bulk action tests ---

  defp create_pending_user do
    import Ecto.Query
    alias Baudrate.Setup.{Role, User}
    role = Repo.one!(from(r in Role, where: r.name == "user"))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "pending_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Ecto.Changeset.put_change(:status, "pending")
      |> Repo.insert()

    user
  end

  describe "bulk select" do
    test "toggle_select adds and removes user from selection", %{conn: conn} do
      admin = setup_user("admin")
      user = setup_user("user")
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/users")

      # Select user
      html = lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{user.id}\"]") |> render_click()
      assert html =~ "1 user selected"

      # Deselect user
      html = lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{user.id}\"]") |> render_click()
      refute html =~ "user selected"
    end

    test "toggle_select_all selects and deselects all users on page", %{conn: conn} do
      admin = setup_user("admin")
      _user1 = setup_user("user")
      _user2 = setup_user("user")
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/users")

      # Select all
      html = lv |> element("input[phx-click=\"toggle_select_all\"]") |> render_click()
      assert html =~ "3 users selected"

      # Deselect all
      html = lv |> element("input[phx-click=\"toggle_select_all\"]") |> render_click()
      refute html =~ "user selected"
    end

    test "selection clears on filter change", %{conn: conn} do
      admin = setup_user("admin")
      user = setup_user("user")
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/users")

      # Select a user
      lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{user.id}\"]") |> render_click()

      # Change filter
      html = lv |> element("button[phx-click=\"filter\"][phx-value-status=\"active\"]") |> render_click()
      refute html =~ "user selected"
    end

    test "selection clears on search", %{conn: conn} do
      admin = setup_user("admin")
      user = setup_user("user")
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/users")

      # Select a user
      lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{user.id}\"]") |> render_click()

      # Search
      html = lv |> form("form[phx-change=\"search\"]", search: "xyz") |> render_change()
      refute html =~ "user selected"
    end
  end

  describe "bulk approve" do
    test "approves all selected pending users", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_user(conn, admin)

      pending1 = create_pending_user()
      pending2 = create_pending_user()

      {:ok, lv, _html} = live(conn, "/admin/users?status=pending")

      # Select both
      lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{pending1.id}\"]") |> render_click()
      lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{pending2.id}\"]") |> render_click()

      # Bulk approve
      html = lv |> element("button[phx-click=\"bulk_approve\"]") |> render_click()
      assert html =~ "2 users approved"

      # Verify both are approved
      assert Auth.get_user(pending1.id).status == "active"
      assert Auth.get_user(pending2.id).status == "active"

      # Verify moderation logs with bulk flag
      import Ecto.Query
      logs = Repo.all(from(l in Moderation.Log, where: l.action == "approve_user" and l.actor_id == ^admin.id))
      assert length(logs) == 2
      assert Enum.all?(logs, fn log -> log.details["bulk"] == true end)
    end

    test "approve button only visible when filtered to pending", %{conn: conn} do
      admin = setup_user("admin")
      user = setup_user("user")
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/users")

      # Select a user on "all" filter
      html = lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{user.id}\"]") |> render_click()
      assert html =~ "Ban Selected"
      refute html =~ "Approve Selected"
    end
  end

  describe "bulk ban" do
    test "bans all selected users with shared reason", %{conn: conn} do
      admin = setup_user("admin")
      user1 = setup_user("user")
      user2 = setup_user("user")
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/users")

      # Select both
      lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{user1.id}\"]") |> render_click()
      lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{user2.id}\"]") |> render_click()

      # Open bulk ban modal
      lv |> element("button[phx-click=\"show_bulk_ban_modal\"]") |> render_click()

      # Set reason
      lv |> form("form[phx-change=\"update_bulk_ban_reason\"]", reason: "Spam accounts") |> render_change()

      # Confirm
      html = lv |> element("button[phx-click=\"confirm_bulk_ban\"]") |> render_click()
      assert html =~ "2 users banned"

      # Verify both are banned
      assert Auth.get_user(user1.id).status == "banned"
      assert Auth.get_user(user2.id).status == "banned"

      # Verify moderation logs with bulk flag
      import Ecto.Query
      logs = Repo.all(from(l in Moderation.Log, where: l.action == "ban_user" and l.actor_id == ^admin.id))
      assert length(logs) == 2
      assert Enum.all?(logs, fn log -> log.details["bulk"] == true end)
      assert Enum.all?(logs, fn log -> log.details["reason"] == "Spam accounts" end)
    end

    test "self is excluded from bulk ban selection", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/users")

      # Select only self
      lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{admin.id}\"]") |> render_click()

      # Try to open bulk ban modal
      html = lv |> element("button[phx-click=\"show_bulk_ban_modal\"]") |> render_click()
      assert html =~ "No users selected for ban"
    end

    test "cancel bulk ban modal closes it", %{conn: conn} do
      admin = setup_user("admin")
      user = setup_user("user")
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/users")

      # Select and open modal
      lv |> element("input[phx-click=\"toggle_select\"][phx-value-id=\"#{user.id}\"]") |> render_click()
      lv |> element("button[phx-click=\"show_bulk_ban_modal\"]") |> render_click()

      # Cancel
      html = lv |> element("button[phx-click=\"cancel_bulk_ban\"]") |> render_click()
      refute html =~ "bulk-ban-modal-title"
    end
  end
end
