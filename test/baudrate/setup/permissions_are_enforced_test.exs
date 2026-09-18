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
  # each needs wiring to a real check or removing. See ADR 0042, which records
  # the decision about the catalogue as a whole.
  #
  # This list is deliberately explicit rather than a relaxed assertion: adding
  # an eighth unenforced permission fails the build.
  #
  # It was five until documentation was stripped from the search (below).
  # `moderator.manage_content` and `guest.view_content` passed only because
  # `lib/baudrate/setup/permission.ex` quotes them as examples in its
  # `@moduledoc` — so the gate reported them enforced while nothing checked
  # them, which is the same vacuity the `@catalogue` exclusion was added to fix.
  @known_unenforced ~w(
    admin.manage_settings
    guest.view_content
    moderator.manage_comments
    moderator.manage_content
    moderator.view_reports
    user.edit_own_content
    user.manage_profile
  )

  # Documentation is not enforcement. A permission named in a `@moduledoc`,
  # a `@doc` or any heredoc does not gate anything, so those are removed before
  # the search — otherwise one illustrative mention anywhere in `lib/` hides a
  # dead permission from this gate for good. Stripping the whole class beats
  # excluding files one at a time, which is how two of them got through.
  #
  # If a permission string ever does live inside a heredoc *and* do real work,
  # this reports it as unenforced — the safe direction to be wrong in.
  defp code_only(source) do
    source
    |> String.replace(~r/"""[\s\S]*?"""/, "")
    |> String.replace(~r/@(?:module)?doc\s+"(?:[^"\\]|\\.)*"/, "")
  end

  defp unchecked_permissions(permissions) do
    sources =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @catalogue))
      |> Enum.map_join("\n", &(&1 |> File.read!() |> code_only()))

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
