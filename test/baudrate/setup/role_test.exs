defmodule Baudrate.Setup.RoleTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Setup.Role

  describe "changeset/2" do
    test "valid changeset with name" do
      changeset = Role.changeset(%Role{}, %{name: "admin"})
      assert changeset.valid?
    end

    test "valid changeset with name and description" do
      changeset = Role.changeset(%Role{}, %{name: "admin", description: "Full access"})
      assert changeset.valid?
    end

    test "requires name" do
      changeset = Role.changeset(%Role{}, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    # The seeded roles are committed before the suite (test_helper.exs), so a
    # test that inserts one uses a name of its own.
    test "enforces unique name constraint" do
      name = "role_#{System.unique_integer([:positive])}"
      {:ok, _} = Repo.insert(Role.changeset(%Role{}, %{name: name}))

      {:error, changeset} = Repo.insert(Role.changeset(%Role{}, %{name: name}))
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
