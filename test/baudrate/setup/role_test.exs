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

    test "enforces unique name constraint" do
      {:ok, _} = Repo.insert(Role.changeset(%Role{}, %{name: "admin"}))

      {:error, changeset} = Repo.insert(Role.changeset(%Role{}, %{name: "admin"}))
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
