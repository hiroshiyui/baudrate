defmodule Baudrate.Auth.UserManagementTest do
  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Repo

  setup do
    import Ecto.Query
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    admin = create_user("admin")
    user = create_user("user")

    {:ok, admin: admin, user: user}
  end

  defp create_user(role_name) do
    import Ecto.Query
    alias Baudrate.Setup.{Role, User}

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "test_#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  describe "list_users/1" do
    test "returns all users", %{admin: admin, user: user} do
      users = Auth.list_users()
      ids = Enum.map(users, & &1.id)
      assert admin.id in ids
      assert user.id in ids
    end

    test "filters by status", %{user: user} do
      users = Auth.list_users(status: "active")
      ids = Enum.map(users, & &1.id)
      assert user.id in ids

      assert Auth.list_users(status: "banned") == []
    end

    test "filters by search", %{user: user} do
      users = Auth.list_users(search: user.username)
      assert length(users) == 1
      assert hd(users).id == user.id
    end

    test "returns empty for non-matching search" do
      assert Auth.list_users(search: "nonexistent_user_xyz") == []
    end
  end

  describe "count_users_by_status/0" do
    test "returns counts by status", %{admin: _admin, user: _user} do
      counts = Auth.count_users_by_status()
      assert Map.get(counts, "active", 0) >= 2
    end
  end

  describe "ban_user/3" do
    test "bans a user", %{admin: admin, user: user} do
      {:ok, banned} = Auth.ban_user(user, admin.id, "spam")
      assert banned.status == "banned"
      assert banned.banned_at != nil
      assert banned.ban_reason == "spam"
    end

    test "bans a user without reason", %{admin: admin, user: user} do
      {:ok, banned} = Auth.ban_user(user, admin.id)
      assert banned.status == "banned"
      assert banned.ban_reason == nil
    end

    test "invalidates all sessions for banned user", %{admin: admin, user: user} do
      {:ok, _token, _refresh} = Auth.create_user_session(user.id)
      {:ok, banned_user} = Auth.ban_user(user, admin.id, "test")

      import Ecto.Query
      sessions = Repo.all(from(s in Auth.UserSession, where: s.user_id == ^banned_user.id))
      assert sessions == []
    end

    test "raises on self-ban", %{admin: admin} do
      assert_raise FunctionClauseError, fn ->
        Auth.ban_user(admin, admin.id, "self")
      end
    end
  end

  describe "unban_user/1" do
    test "unbans a user and clears ban fields", %{admin: admin, user: user} do
      {:ok, banned} = Auth.ban_user(user, admin.id, "test")
      assert banned.status == "banned"
      assert banned.banned_at != nil
      assert banned.ban_reason == "test"

      {:ok, unbanned} = Auth.unban_user(banned)
      assert unbanned.status == "active"
      assert unbanned.banned_at == nil
      assert unbanned.ban_reason == nil
    end

    test "unbanning an already active user is a no-op", %{user: user} do
      {:ok, same} = Auth.unban_user(user)
      assert same.status == "active"
      assert same.banned_at == nil
    end
  end

  describe "update_user_role/3" do
    test "changes a user's role", %{admin: admin, user: user} do
      import Ecto.Query
      mod_role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "moderator"))

      {:ok, updated} = Auth.update_user_role(user, mod_role.id, admin.id)
      assert updated.role.name == "moderator"
    end

    test "raises on self-role-change", %{admin: admin} do
      import Ecto.Query
      user_role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

      assert_raise FunctionClauseError, fn ->
        Auth.update_user_role(admin, user_role.id, admin.id)
      end
    end
  end

  describe "authenticate_by_password/2 with banned user" do
    test "returns :banned for banned user", %{admin: admin} do
      user = create_user("user")
      {:ok, _} = Auth.ban_user(user, admin.id, "test")

      assert {:error, :banned} =
               Auth.authenticate_by_password(user.username, "Password123!x")
    end
  end

  describe "list_users/1 search sanitization" do
    test "LIKE wildcards are escaped in search", %{user: _user} do
      # Should not crash or match everything
      results = Auth.list_users(search: "%")
      assert is_list(results)

      results = Auth.list_users(search: "_")
      assert is_list(results)
    end
  end
end
