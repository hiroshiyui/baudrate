defmodule Baudrate.Auth.UserManagementTest do
  use Baudrate.DataCase

  import Ecto.Query

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
      {:ok, banned, _revoked} = Auth.ban_user(user, admin, "spam")
      assert banned.status == "banned"
      assert banned.banned_at != nil
      assert banned.ban_reason == "spam"
    end

    test "bans a user without reason", %{admin: admin, user: user} do
      {:ok, banned, _revoked} = Auth.ban_user(user, admin)
      assert banned.status == "banned"
      assert banned.ban_reason == nil
    end

    test "invalidates all sessions for banned user", %{admin: admin, user: user} do
      {:ok, _token, _refresh} = Auth.create_user_session(user.id)
      {:ok, banned_user, _revoked} = Auth.ban_user(user, admin, "test")

      import Ecto.Query
      sessions = Repo.all(from(s in Auth.UserSession, where: s.user_id == ^banned_user.id))
      assert sessions == []
    end

    test "returns error on self-ban", %{admin: admin} do
      assert {:error, :self_action} = Auth.ban_user(admin, admin, "self")
    end

    test "rejects ban reason over 500 characters", %{admin: admin, user: user} do
      long_reason = String.duplicate("x", 501)
      {:error, changeset} = Auth.ban_user(user, admin, long_reason)
      assert changeset.errors[:ban_reason]
    end
  end

  describe "unban_user/1" do
    test "unbans a user and clears ban fields", %{admin: admin, user: user} do
      {:ok, banned, _revoked} = Auth.ban_user(user, admin, "test")
      assert banned.status == "banned"
      assert banned.banned_at != nil
      assert banned.ban_reason == "test"

      {:ok, unbanned} = Auth.unban_user(banned, admin)
      assert unbanned.status == "active"
      assert unbanned.banned_at == nil
      assert unbanned.ban_reason == nil
    end

    test "unbanning an already active user is a no-op", %{user: user, admin: admin} do
      {:ok, same} = Auth.unban_user(user, admin)
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

    test "returns error on self-role-change", %{admin: admin} do
      import Ecto.Query
      user_role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

      assert {:error, :self_action} = Auth.update_user_role(admin, user_role.id, admin.id)
    end
  end

  describe "authenticate_by_password/2 with banned user" do
    test "returns :banned for banned user", %{admin: admin} do
      user = create_user("user")
      {:ok, _, _} = Auth.ban_user(user, admin, "test")

      assert {:error, :banned} =
               Auth.authenticate_by_password(user.username, "Password123!x")
    end
  end

  describe "list_users/1 search sanitization" do
    # `assert is_list(...)` proved nothing here: `list_users/1` is a
    # `Repo.all/1`, so it returns a list whether or not the pattern is
    # escaped. Dropping `Repo.sanitize_like/1` left the test green while `%`
    # matched every account on the instance.
    test "an underscore matches a literal underscore, not any character" do
      n = System.unique_integer([:positive])
      {:ok, plain} = create_user_named("alpha#{n}")
      {:ok, scored} = create_user_named("beta#{n}x_y")

      found = Auth.list_users(search: "_") |> Enum.map(& &1.id)

      # Unescaped, `_` is a single-character wildcard and `%_%` matches every
      # username on the instance. Escaped, it matches only the one that
      # really contains an underscore.
      assert scored.id in found
      refute plain.id in found
    end

    test "a percent matches a literal percent, so it matches no username at all" do
      n = System.unique_integer([:positive])
      {:ok, plain} = create_user_named("gamma#{n}")

      # Usernames are `[A-Za-z0-9_]` only, so no username can contain `%`.
      # Unescaped, `%%%` matches all of them.
      assert Auth.list_users(search: "%") == []

      # Positive control: the search itself works.
      assert Enum.any?(Auth.list_users(search: "gamma#{n}"), &(&1.id == plain.id))
    end
  end

  defp create_user_named(username) do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    %Baudrate.Setup.User{}
    |> Baudrate.Setup.User.registration_changeset(%{
      "username" => username,
      "password" => "Password123!x",
      "password_confirmation" => "Password123!x",
      "role_id" => role.id
    })
    |> Repo.insert()
  end
end
