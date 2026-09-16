defmodule Baudrate.Setup.PermissionsAreEnforcedTest do
  @moduledoc """
  A listed permission that enforces nothing is a false statement about who can
  do what (ADR 0029). Every permission in the catalogue must be checked
  somewhere in `lib/`.
  """

  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup

  test "every permission in the catalogue is checked somewhere in lib/" do
    sources =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    permissions =
      Setup.default_permissions() |> Map.values() |> List.flatten() |> Enum.uniq()

    unchecked = Enum.reject(permissions, &String.contains?(sources, "\"#{&1}\""))

    assert unchecked == [],
           """
           These permissions are granted to roles but never checked. Wire each
           one to a real check, or remove it — a permission that enforces
           nothing tells the operator a lie about who can do what:

           #{Enum.map_join(unchecked, "\n", &"  - #{&1}")}
           """
  end

  describe "admin.manage_roles" do
    setup do
      Setup.seed_roles_and_permissions()
      %{admin: user("admin"), moderator: user("moderator"), member: user("user")}
    end

    test "an admin can change a role", %{admin: admin, member: member} do
      moderator_role = Repo.one!(from(r in Setup.Role, where: r.name == "moderator"))

      assert {:ok, updated} = Auth.update_user_role(member, moderator_role.id, admin.id)
      assert updated.role.name == "moderator"
    end

    test "a moderator cannot, even though the LiveView would never offer it", %{
      moderator: mod,
      member: member
    } do
      moderator_role = Repo.one!(from(r in Setup.Role, where: r.name == "moderator"))

      assert Auth.update_user_role(member, moderator_role.id, mod.id) == {:error, :unauthorized}
      assert Repo.get!(Setup.User, member.id).role_id == member.role_id
    end

    test "nobody changes their own role", %{admin: admin} do
      role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))
      assert Auth.update_user_role(admin, role.id, admin.id) == {:error, :self_action}
    end
  end

  defp user(role_name) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in Setup.User, where: u.id == ^user.id), set: [status: "active"])
    Repo.get!(Setup.User, user.id) |> Repo.preload(:role)
  end
end
