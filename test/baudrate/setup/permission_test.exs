defmodule Baudrate.Setup.PermissionTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Setup.Permission

  describe "changeset/2" do
    test "valid changeset with name" do
      changeset = Permission.changeset(%Permission{}, %{name: "admin.manage_users"})
      assert changeset.valid?
    end

    test "valid changeset with name and description" do
      changeset =
        Permission.changeset(%Permission{}, %{
          name: "admin.manage_users",
          description: "Manage users"
        })

      assert changeset.valid?
    end

    test "requires name" do
      changeset = Permission.changeset(%Permission{}, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    # The seeded permissions are committed before the suite (test_helper.exs),
    # so this uses a name of its own.
    test "enforces unique name constraint" do
      name = "test.permission_#{System.unique_integer([:positive])}"
      {:ok, _} = Repo.insert(Permission.changeset(%Permission{}, %{name: name}))

      {:error, changeset} = Repo.insert(Permission.changeset(%Permission{}, %{name: name}))

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
