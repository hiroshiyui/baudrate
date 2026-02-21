defmodule Baudrate.SetupTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, Setting}

  describe "setup_completed?/0" do
    test "returns false when no settings exist" do
      refute Setup.setup_completed?()
    end

    test "returns false when setup_completed setting is not true" do
      Repo.insert!(%Setting{key: "setup_completed", value: "false"})
      refute Setup.setup_completed?()
    end

    test "returns true when setup_completed is true" do
      Repo.insert!(%Setting{key: "setup_completed", value: "true"})
      assert Setup.setup_completed?()
    end
  end

  describe "check_database/0" do
    test "returns ok with database info" do
      assert {:ok, info} = Setup.check_database()
      assert info.version
      assert info.database
    end
  end

  describe "check_migrations/0" do
    test "returns ok when all migrations are applied" do
      assert {:ok, count} = Setup.check_migrations()
      assert count > 0
    end
  end

  describe "change_site_name/1" do
    test "returns valid changeset for valid site name" do
      changeset = Setup.change_site_name(%{site_name: "My Site"})
      assert changeset.valid?
    end

    test "returns invalid changeset when site name is empty" do
      changeset = Setup.change_site_name(%{site_name: ""})
      refute changeset.valid?
    end

    test "returns invalid changeset when site name is missing" do
      changeset = Setup.change_site_name(%{})
      refute changeset.valid?
    end
  end

  describe "complete_setup/2" do
    @valid_user_attrs %{
      "username" => "admin",
      "password" => "SecurePass1!xyz",
      "password_confirmation" => "SecurePass1!xyz"
    }

    test "creates settings, seeds roles/permissions, and admin user in a transaction" do
      assert {:ok, result} = Setup.complete_setup("My Site", @valid_user_attrs)
      assert result.site_name.key == "site_name"
      assert result.site_name.value == "My Site"
      assert result.admin_user.username == "admin"
      assert result.admin_user.hashed_password
      assert result.setup_completed.key == "setup_completed"
      assert result.setup_completed.value == "true"
    end

    test "seeds all 4 roles" do
      assert {:ok, result} = Setup.complete_setup("My Site", @valid_user_attrs)
      %{roles: roles} = result.seed_permissions
      assert map_size(roles) == 4
      assert Map.has_key?(roles, "admin")
      assert Map.has_key?(roles, "moderator")
      assert Map.has_key?(roles, "user")
      assert Map.has_key?(roles, "guest")
    end

    test "seeds all 12 permissions" do
      assert {:ok, result} = Setup.complete_setup("My Site", @valid_user_attrs)
      %{permissions: permissions} = result.seed_permissions
      assert length(permissions) == 12
    end

    test "seeds 26 role_permission mappings" do
      assert {:ok, _result} = Setup.complete_setup("My Site", @valid_user_attrs)

      count =
        Repo.one(
          from rp in Baudrate.Setup.RolePermission,
            select: count(rp.id)
        )

      assert count == 25
    end

    test "assigns admin role to the created user" do
      assert {:ok, result} = Setup.complete_setup("My Site", @valid_user_attrs)
      admin_role = result.seed_permissions.roles["admin"]
      assert result.admin_user.role_id == admin_role.id
    end

    test "rolls back on invalid user attrs" do
      assert {:error, :admin_user, _changeset, _changes} =
               Setup.complete_setup("My Site", %{"username" => ""})

      # Verify nothing was persisted
      refute Repo.get_by(Setting, key: "site_name")
      refute Repo.get_by(Setting, key: "setup_completed")
      assert Repo.all(Role) == []
    end

    test "marks setup as completed" do
      refute Setup.setup_completed?()
      assert {:ok, _} = Setup.complete_setup("My Site", @valid_user_attrs)
      assert Setup.setup_completed?()
    end
  end

  describe "change_settings/1" do
    setup do
      Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
      Repo.insert!(%Setting{key: "registration_mode", value: "approval_required"})
      :ok
    end

    test "returns valid changeset with current defaults" do
      changeset = Setup.change_settings()
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :site_name) == "Test Site"
      assert Ecto.Changeset.get_field(changeset, :registration_mode) == "approval_required"
    end

    test "returns valid changeset for valid attrs" do
      changeset = Setup.change_settings(%{"site_name" => "New Name", "registration_mode" => "open"})
      assert changeset.valid?
    end

    test "returns invalid changeset when site_name is blank" do
      changeset = Setup.change_settings(%{"site_name" => "", "registration_mode" => "open"})
      refute changeset.valid?
    end

    test "returns invalid changeset when registration_mode is invalid" do
      changeset = Setup.change_settings(%{"site_name" => "Test", "registration_mode" => "invalid"})
      refute changeset.valid?
    end

    test "validates site_name max length" do
      long_name = String.duplicate("a", 256)
      changeset = Setup.change_settings(%{"site_name" => long_name, "registration_mode" => "open"})
      refute changeset.valid?
    end
  end

  describe "save_settings/1" do
    setup do
      Repo.insert!(%Setting{key: "site_name", value: "Original"})
      Repo.insert!(%Setting{key: "registration_mode", value: "approval_required"})
      :ok
    end

    test "saves valid settings" do
      assert {:ok, changes} =
               Setup.save_settings(%{"site_name" => "Updated", "registration_mode" => "open"})

      assert changes.site_name == "Updated"
      assert changes.registration_mode == "open"
      assert Setup.get_setting("site_name") == "Updated"
      assert Setup.get_setting("registration_mode") == "open"
    end

    test "returns error changeset for invalid attrs" do
      assert {:error, changeset} =
               Setup.save_settings(%{"site_name" => "", "registration_mode" => "open"})

      refute changeset.valid?
      assert changeset.action == :validate
      # Original values unchanged
      assert Setup.get_setting("site_name") == "Original"
    end

    test "returns error for invalid registration mode" do
      assert {:error, changeset} =
               Setup.save_settings(%{"site_name" => "Test", "registration_mode" => "closed"})

      refute changeset.valid?
    end
  end

  describe "default_permissions/0" do
    test "returns a map with 4 roles" do
      permissions = Setup.default_permissions()
      assert map_size(permissions) == 4
    end

    test "admin has all 12 permissions" do
      assert length(Setup.default_permissions()["admin"]) == 12
    end

    test "guest has only view_content" do
      assert Setup.default_permissions()["guest"] == ["guest.view_content"]
    end
  end

  describe "has_permission?/2" do
    setup do
      {:ok, _} =
        Setup.complete_setup("My Site", %{
          "username" => "admin",
          "password" => "SecurePass1!xyz",
          "password_confirmation" => "SecurePass1!xyz"
        })

      :ok
    end

    test "returns true for admin with admin.manage_users" do
      assert Setup.has_permission?("admin", "admin.manage_users")
    end

    test "returns true for guest with guest.view_content" do
      assert Setup.has_permission?("guest", "guest.view_content")
    end

    test "returns false for guest with admin.manage_users" do
      refute Setup.has_permission?("guest", "admin.manage_users")
    end

    test "returns false for moderator with admin.manage_settings" do
      refute Setup.has_permission?("moderator", "admin.manage_settings")
    end

    test "returns true for moderator with moderator.manage_content" do
      assert Setup.has_permission?("moderator", "moderator.manage_content")
    end

    test "returns false for nonexistent role" do
      refute Setup.has_permission?("nonexistent", "admin.manage_users")
    end
  end

  describe "permissions_for_role/1" do
    setup do
      {:ok, _} =
        Setup.complete_setup("My Site", %{
          "username" => "admin",
          "password" => "SecurePass1!xyz",
          "password_confirmation" => "SecurePass1!xyz"
        })

      :ok
    end

    test "returns all 12 permissions for admin" do
      perms = Setup.permissions_for_role("admin")
      assert length(perms) == 12
    end

    test "returns 8 permissions for moderator" do
      perms = Setup.permissions_for_role("moderator")
      assert length(perms) == 8
    end

    test "returns 4 permissions for user" do
      perms = Setup.permissions_for_role("user")
      assert length(perms) == 4
    end

    test "returns 1 permission for guest" do
      perms = Setup.permissions_for_role("guest")
      assert perms == ["guest.view_content"]
    end

    test "returns empty list for nonexistent role" do
      assert Setup.permissions_for_role("nonexistent") == []
    end
  end

  describe "all_roles/0" do
    test "returns empty list when no roles exist" do
      assert Setup.all_roles() == []
    end

    test "returns all roles after setup" do
      {:ok, _} =
        Setup.complete_setup("My Site", %{
          "username" => "admin",
          "password" => "SecurePass1!xyz",
          "password_confirmation" => "SecurePass1!xyz"
        })

      roles = Setup.all_roles()
      assert length(roles) == 4
      role_names = Enum.map(roles, & &1.name)
      assert "admin" in role_names
      assert "moderator" in role_names
      assert "user" in role_names
      assert "guest" in role_names
    end
  end
end
