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

  # The file that *defines* the catalogue. It has to be excluded from the
  # search, or the test is a tautology: `Path.wildcard("lib/**/*.ex")` reads
  # `lib/baudrate/setup.ex` too, so every permission string was always found
  # in `sources` and `unchecked` could never be non-empty. The gate passed for
  # two years while five permissions enforced nothing.
  @catalogue "lib/baudrate/setup.ex"

  # Permissions that are granted but not consulted anywhere. Each capability
  # *is* guarded — by a role hook on the route and an authorship or role check
  # in the context — so none of these is an open door; the permission row
  # simply is not what closes it. That still makes the catalogue a misleading
  # answer to "who can do what", which ADR 0029 says is the thing to avoid, so
  # each needs wiring to a real check or removing. Tracked in `doc/TODOs.md`.
  #
  # This list is deliberately explicit rather than a relaxed assertion: adding
  # a sixth unenforced permission fails the build.
  @known_unenforced ~w(
    admin.manage_settings
    moderator.manage_comments
    moderator.view_reports
    user.edit_own_content
    user.manage_profile
  )

  defp unchecked_permissions(permissions) do
    sources =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @catalogue))
      |> Enum.map_join("\n", &File.read!/1)

    Enum.reject(permissions, &String.contains?(sources, "\"#{&1}\""))
  end

  test "every permission in the catalogue is checked somewhere in lib/" do
    permissions =
      Setup.default_permissions() |> Map.values() |> List.flatten() |> Enum.uniq()

    unchecked = unchecked_permissions(permissions) -- @known_unenforced

    assert unchecked == [],
           """
           These permissions are granted to roles but never checked. Wire each
           one to a real check, or remove it — a permission that enforces
           nothing tells the operator a lie about who can do what:

           #{Enum.map_join(unchecked, "\n", &"  - #{&1}")}
           """
  end

  test "the search can actually fail, and the exemption list is not stale" do
    # Without this, excluding the catalogue could regress to a tautology again
    # and nothing would say so.
    assert unchecked_permissions(["baudrate.no_such_permission"]) ==
             ["baudrate.no_such_permission"],
           "the search matches a permission that appears nowhere — the gate is vacuous again"

    still_unenforced = unchecked_permissions(@known_unenforced)

    assert Enum.sort(still_unenforced) == Enum.sort(@known_unenforced),
           """
           One of the known-unenforced permissions is now checked in lib/.
           Remove it from @known_unenforced so the gate protects it:

           #{Enum.map_join(@known_unenforced -- still_unenforced, "\n", &"  - #{&1}")}
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
