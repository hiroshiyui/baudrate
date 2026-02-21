defmodule Baudrate.Auth.InviteSystemTest do
  use Baudrate.DataCase

  alias Baudrate.Auth

  setup do
    user = setup_user("admin")
    {:ok, user: user}
  end

  describe "generate_invite_code/2" do
    test "generates a code", %{user: user} do
      assert {:ok, invite} = Auth.generate_invite_code(user.id)
      assert is_binary(invite.code)
      assert String.length(invite.code) == 8
      assert invite.max_uses == 1
      assert invite.use_count == 0
      assert invite.revoked == false
    end

    test "generates code with custom max_uses", %{user: user} do
      assert {:ok, invite} = Auth.generate_invite_code(user.id, max_uses: 5)
      assert invite.max_uses == 5
    end

    test "generates code with expiry", %{user: user} do
      assert {:ok, invite} = Auth.generate_invite_code(user.id, expires_in_days: 7)
      assert invite.expires_at != nil
    end
  end

  describe "validate_invite_code/1" do
    test "returns {:ok, invite} for valid code", %{user: user} do
      {:ok, invite} = Auth.generate_invite_code(user.id)
      assert {:ok, validated} = Auth.validate_invite_code(invite.code)
      assert validated.id == invite.id
    end

    test "returns error for nonexistent code" do
      assert {:error, :not_found} = Auth.validate_invite_code("nonexistent")
    end

    test "returns error for revoked code", %{user: user} do
      {:ok, invite} = Auth.generate_invite_code(user.id)
      {:ok, _} = Auth.revoke_invite_code(invite)

      assert {:error, :revoked} = Auth.validate_invite_code(invite.code)
    end

    test "returns error for expired code", %{user: user} do
      {:ok, invite} = Auth.generate_invite_code(user.id, expires_in_days: -1)

      assert {:error, :expired} = Auth.validate_invite_code(invite.code)
    end

    test "returns error for fully used code", %{user: user} do
      {:ok, invite} = Auth.generate_invite_code(user.id, max_uses: 1)
      other_user = setup_user("user")
      {:ok, _} = Auth.use_invite_code(invite, other_user.id)

      assert {:error, :fully_used} = Auth.validate_invite_code(invite.code)
    end
  end

  describe "use_invite_code/2" do
    test "increments use_count", %{user: user} do
      {:ok, invite} = Auth.generate_invite_code(user.id)
      other_user = setup_user("user")

      {:ok, used} = Auth.use_invite_code(invite, other_user.id)
      assert used.use_count == 1
      assert used.used_by_id == other_user.id
      assert used.used_at != nil
    end
  end

  describe "revoke_invite_code/1" do
    test "sets revoked to true", %{user: user} do
      {:ok, invite} = Auth.generate_invite_code(user.id)
      {:ok, revoked} = Auth.revoke_invite_code(invite)
      assert revoked.revoked == true
    end
  end

  describe "list_all_invite_codes/0" do
    test "returns all codes newest first", %{user: user} do
      {:ok, _} = Auth.generate_invite_code(user.id)
      {:ok, _} = Auth.generate_invite_code(user.id)

      codes = Auth.list_all_invite_codes()
      assert length(codes) == 2
    end
  end

  defp setup_user(role_name) do
    import Ecto.Query
    alias Baudrate.Repo
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

    Repo.preload(user, :role)
  end
end
