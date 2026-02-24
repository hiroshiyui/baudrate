defmodule Baudrate.Auth.InviteSystemTest do
  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Auth.InviteCode
  alias Baudrate.Repo

  setup do
    admin = setup_user("admin", days_old: 8)
    {:ok, admin: admin}
  end

  describe "generate_invite_code/2" do
    test "generates a code", %{admin: admin} do
      assert {:ok, invite} = Auth.generate_invite_code(admin)
      assert is_binary(invite.code)
      assert String.length(invite.code) == 8
      assert invite.max_uses == 1
      assert invite.use_count == 0
      assert invite.revoked == false
    end

    test "generates code with custom max_uses", %{admin: admin} do
      assert {:ok, invite} = Auth.generate_invite_code(admin, max_uses: 5)
      assert invite.max_uses == 5
    end

    test "generates code with expiry", %{admin: admin} do
      assert {:ok, invite} = Auth.generate_invite_code(admin, expires_in_days: 7)
      assert invite.expires_at != nil
    end
  end

  describe "validate_invite_code/1" do
    test "returns {:ok, invite} for valid code", %{admin: admin} do
      {:ok, invite} = Auth.generate_invite_code(admin)
      assert {:ok, validated} = Auth.validate_invite_code(invite.code)
      assert validated.id == invite.id
    end

    test "returns error for nonexistent code" do
      assert {:error, :not_found} = Auth.validate_invite_code("nonexistent")
    end

    test "returns error for revoked code", %{admin: admin} do
      {:ok, invite} = Auth.generate_invite_code(admin)
      {:ok, _} = Auth.revoke_invite_code(invite)

      assert {:error, :revoked} = Auth.validate_invite_code(invite.code)
    end

    test "returns error for expired code", %{admin: admin} do
      {:ok, invite} = Auth.generate_invite_code(admin, expires_in_days: -1)

      assert {:error, :expired} = Auth.validate_invite_code(invite.code)
    end

    test "returns error for fully used code", %{admin: admin} do
      {:ok, invite} = Auth.generate_invite_code(admin, max_uses: 1)
      other_user = setup_user("user")
      {:ok, _} = Auth.use_invite_code(invite, other_user.id)

      assert {:error, :fully_used} = Auth.validate_invite_code(invite.code)
    end
  end

  describe "use_invite_code/2" do
    test "increments use_count", %{admin: admin} do
      {:ok, invite} = Auth.generate_invite_code(admin)
      other_user = setup_user("user")

      {:ok, used} = Auth.use_invite_code(invite, other_user.id)
      assert used.use_count == 1
      assert used.used_by_id == other_user.id
      assert used.used_at != nil
    end
  end

  describe "revoke_invite_code/1" do
    test "sets revoked to true", %{admin: admin} do
      {:ok, invite} = Auth.generate_invite_code(admin)
      {:ok, revoked} = Auth.revoke_invite_code(invite)
      assert revoked.revoked == true
    end
  end

  describe "list_all_invite_codes/0" do
    test "returns all codes newest first", %{admin: admin} do
      {:ok, _} = Auth.generate_invite_code(admin)
      {:ok, _} = Auth.generate_invite_code(admin)

      codes = Auth.list_all_invite_codes()
      assert length(codes) == 2
    end
  end

  describe "invite code quota" do
    test "non-admin can generate up to 5 codes" do
      user = setup_user("user", days_old: 8)

      for _ <- 1..5 do
        assert {:ok, _invite} = Auth.generate_invite_code(user)
      end
    end

    test "6th code returns :invite_quota_exceeded for non-admin" do
      user = setup_user("user", days_old: 8)

      for _ <- 1..5 do
        assert {:ok, _} = Auth.generate_invite_code(user)
      end

      assert {:error, :invite_quota_exceeded} = Auth.generate_invite_code(user)
    end

    test "admin is not limited (6+ codes succeed)", %{admin: admin} do
      for _ <- 1..6 do
        assert {:ok, _} = Auth.generate_invite_code(admin)
      end
    end

    test "codes older than 30 days don't count towards quota" do
      import Ecto.Query
      user = setup_user("user", days_old: 60)

      # Generate 5 codes and backdate them to 31 days ago
      for _ <- 1..5 do
        {:ok, _} = Auth.generate_invite_code(user)
      end

      past =
        DateTime.utc_now() |> DateTime.add(-31 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(i in InviteCode, where: i.created_by_id == ^user.id),
        set: [inserted_at: past]
      )

      # Should be able to generate again
      assert {:ok, _} = Auth.generate_invite_code(user)
    end

    test "invite_quota_remaining/1 returns correct count" do
      user = setup_user("user", days_old: 8)
      assert Auth.invite_quota_remaining(user) == 5

      {:ok, _} = Auth.generate_invite_code(user)
      assert Auth.invite_quota_remaining(user) == 4

      {:ok, _} = Auth.generate_invite_code(user)
      assert Auth.invite_quota_remaining(user) == 3
    end

    test "account younger than 7 days returns :account_too_new" do
      user = setup_user("user", days_old: 3)
      assert {:error, :account_too_new} = Auth.generate_invite_code(user)
    end

    test "non-admin codes auto-expire after 7 days" do
      user = setup_user("user", days_old: 8)
      {:ok, invite} = Auth.generate_invite_code(user)

      assert invite.expires_at != nil
      # Should expire roughly 7 days from now (within a minute tolerance)
      expected = DateTime.utc_now() |> DateTime.add(7 * 86_400, :second)
      diff = abs(DateTime.diff(invite.expires_at, expected, :second))
      assert diff < 60
    end

    test "admin codes have no expiry by default", %{admin: admin} do
      {:ok, invite} = Auth.generate_invite_code(admin)
      assert invite.expires_at == nil
    end
  end

  describe "list_user_invite_codes/1" do
    test "returns only codes for the given user", %{admin: admin} do
      user = setup_user("user", days_old: 8)

      {:ok, _} = Auth.generate_invite_code(admin)
      {:ok, _} = Auth.generate_invite_code(admin)
      {:ok, _} = Auth.generate_invite_code(user)

      admin_codes = Auth.list_user_invite_codes(admin)
      assert length(admin_codes) == 2

      user_codes = Auth.list_user_invite_codes(user)
      assert length(user_codes) == 1
    end
  end

  describe "revoke on ban" do
    test "banning a user revokes their active invite codes" do
      user = setup_user("user", days_old: 8)
      admin = setup_user("admin", days_old: 8)

      {:ok, code1} = Auth.generate_invite_code(user)
      {:ok, code2} = Auth.generate_invite_code(user)
      assert code1.revoked == false
      assert code2.revoked == false

      {:ok, _banned_user, revoked_count} = Auth.ban_user(user, admin.id, "spam")
      assert revoked_count == 2

      # Verify codes are revoked
      updated1 = Repo.get!(InviteCode, code1.id)
      updated2 = Repo.get!(InviteCode, code2.id)
      assert updated1.revoked == true
      assert updated2.revoked == true
    end

    test "already-revoked/expired/fully-used codes are not affected" do
      user = setup_user("user", days_old: 8)
      admin = setup_user("admin", days_old: 8)

      # Already revoked
      {:ok, revoked_code} = Auth.generate_invite_code(user)
      {:ok, _} = Auth.revoke_invite_code(revoked_code)

      # Expired
      {:ok, expired_code} = Auth.generate_invite_code(user, expires_in_days: -1)

      # Fully used
      {:ok, used_code} = Auth.generate_invite_code(user, max_uses: 1)
      {:ok, _} = Auth.use_invite_code(used_code, admin.id)

      # Active one
      {:ok, active_code} = Auth.generate_invite_code(user)

      {:ok, _banned_user, revoked_count} = Auth.ban_user(user, admin.id, "spam")
      # Only the active code should be revoked
      assert revoked_count == 1

      # Active code is now revoked
      assert Repo.get!(InviteCode, active_code.id).revoked == true
      # Expired code was not touched (already expired)
      assert Repo.get!(InviteCode, expired_code.id).revoked == false
    end
  end

  describe "invite chain tracking" do
    test "user registered with invite has invited_by_id set to code creator", %{admin: admin} do
      {:ok, invite} = Auth.generate_invite_code(admin)

      # Set up invite-only registration mode
      alias Baudrate.Setup.Setting
      Repo.insert!(%Setting{key: "registration_mode", value: "invite_only"})

      {:ok, new_user, _codes} =
        Auth.register_user(%{
          "username" => "invited_user_#{System.unique_integer([:positive])}",
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "invite_code" => invite.code,
          "terms_accepted" => true
        })

      assert new_user.invited_by_id == admin.id
    end
  end

  defp setup_user(role_name, opts \\ []) do
    import Ecto.Query
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

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

    # Backdate account creation if requested (to satisfy account age checks)
    if days_old = Keyword.get(opts, :days_old) do
      past =
        DateTime.utc_now()
        |> DateTime.add(-days_old * 86_400, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [inserted_at: past])
      %{user | inserted_at: past} |> Repo.preload(:role)
    else
      Repo.preload(user, :role)
    end
  end
end
