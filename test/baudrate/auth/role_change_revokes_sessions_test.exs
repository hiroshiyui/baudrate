defmodule Baudrate.Auth.RoleChangeRevokesSessionsTest do
  @moduledoc """
  A role change ends the account's sessions, like a ban does.

  Authority is read from the user struct loaded at mount, and `on_mount` never
  runs again — so a demoted admin's open `/admin/users` and `/invites` tabs
  went on banning accounts, issuing sanctions and minting unlimited invite
  codes until they happened to reload. `ban_user/3`, `reject_pending_user` and
  suspension all revoke; role changes did not.
  """

  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Auth.UserSession
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.Role

  setup do
    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    :ok
  end

  defp session_count(user_id) do
    Repo.aggregate(from(s in UserSession, where: s.user_id == ^user_id), :count, :id)
  end

  test "demoting an account ends its sessions" do
    acting_admin = setup_user("admin")
    target = setup_user("admin")

    {:ok, _token, _refresh} = Auth.create_user_session(target.id)
    assert session_count(target.id) == 1

    user_role = Repo.one!(from(r in Role, where: r.name == "user"))

    assert {:ok, updated} = Auth.update_user_role(target, user_role.id, acting_admin.id)
    assert updated.role.name == "user"

    assert session_count(target.id) == 0,
           "the demoted account's open sockets must die with its sessions, " <>
             "or they keep acting with the authority they no longer have"
  end

  test "promoting also revokes, so the new authority is loaded fresh" do
    acting_admin = setup_user("admin")
    target = setup_user("user")

    {:ok, _token, _refresh} = Auth.create_user_session(target.id)

    admin_role = Repo.one!(from(r in Role, where: r.name == "admin"))

    assert {:ok, _updated} = Auth.update_user_role(target, admin_role.id, acting_admin.id)
    assert session_count(target.id) == 0
  end
end
