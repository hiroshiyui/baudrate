defmodule Baudrate.Setup.RolePermissionTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Setup.{Permission, Role, RolePermission}

  setup do
    role = Repo.insert!(%Role{name: "admin", inserted_at: DateTime.utc_now() |> DateTime.truncate(:second), updated_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    permission = Repo.insert!(%Permission{name: "admin.manage_users", inserted_at: DateTime.utc_now() |> DateTime.truncate(:second), updated_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    %{role: role, permission: permission}
  end

  describe "changeset/2" do
    test "valid changeset with role_id and permission_id", %{role: role, permission: permission} do
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_id: role.id,
          permission_id: permission.id
        })

      assert changeset.valid?
    end

    test "requires role_id" do
      changeset = RolePermission.changeset(%RolePermission{}, %{permission_id: 1})
      assert %{role_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires permission_id" do
      changeset = RolePermission.changeset(%RolePermission{}, %{role_id: 1})
      assert %{permission_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "enforces unique role_id + permission_id constraint", %{
      role: role,
      permission: permission
    } do
      {:ok, _} =
        Repo.insert(
          RolePermission.changeset(%RolePermission{}, %{
            role_id: role.id,
            permission_id: permission.id
          })
        )

      {:error, changeset} =
        Repo.insert(
          RolePermission.changeset(%RolePermission{}, %{
            role_id: role.id,
            permission_id: permission.id
          })
        )

      assert %{role_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "enforces role foreign key constraint" do
      {:error, changeset} =
        Repo.insert(
          RolePermission.changeset(%RolePermission{}, %{role_id: 0, permission_id: 0})
        )

      assert %{role: ["does not exist"]} = errors_on(changeset)
    end
  end
end
