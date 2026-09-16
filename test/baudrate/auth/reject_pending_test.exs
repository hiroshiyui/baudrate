defmodule Baudrate.Auth.RejectPendingTest do
  @moduledoc """
  Refusing a registration that is still waiting (ADR 0029).

  A refusal is a ban with a reason on a `pending` account, not a new status
  value: every `status != "banned"` check in the codebase already refuses a
  banned account, and none of them would have learned about a `rejected` one.
  """

  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Moderation
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Repo
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()

    %{
      admin: user("admin", "active"),
      moderator: user("moderator", "active"),
      pending: user("user", "pending"),
      member: user("user", "active")
    }
  end

  test "a moderator may refuse a pending registration", %{moderator: mod, pending: pending} do
    assert {:ok, rejected} = Auth.reject_pending_user(mod, pending, "Obvious spam")

    assert rejected.status == "banned"
    assert rejected.ban_reason == "Obvious spam"
    assert rejected.banned_at
  end

  test "the refused account cannot sign in", %{moderator: mod, pending: pending} do
    {:ok, _} = Auth.reject_pending_user(mod, pending, "Obvious spam")

    assert Auth.authenticate_by_password(pending.username, "Password123!x") ==
             {:error, :banned}
  end

  test "it is logged as a refusal, not as a ban", %{moderator: mod, pending: pending} do
    {:ok, _} = Auth.reject_pending_user(mod, pending, "Obvious spam")

    assert Repo.exists?(
             from(l in Moderation.Log,
               where:
                 l.actor_id == ^mod.id and l.action == "reject_user" and
                   l.target_id == ^pending.id
             )
           )

    refute Repo.exists?(from(l in Moderation.Log, where: l.action == "ban_user"))
  end

  test "an account that was already let in is not refused", %{moderator: mod, member: member} do
    assert Auth.reject_pending_user(mod, member, "Too late") == {:error, :not_pending}
    assert Repo.get!(Setup.User, member.id).status == "active"
  end

  test "an ordinary member cannot refuse anyone", %{member: member, pending: pending} do
    assert Auth.reject_pending_user(member, pending, "No") == {:error, :unauthorized}
  end

  test "refusing says nothing to the refused account", %{moderator: mod, pending: pending} do
    # There is nowhere to read it: the account can never sign in.
    {:ok, _} = Auth.reject_pending_user(mod, pending, "Obvious spam")

    refute Repo.exists?(from(n in NotificationSchema, where: n.user_id == ^pending.id))
  end

  test "staff hear about a registration that needs a decision", %{admin: admin} do
    Setup.set_setting("registration_mode", "approval_required")

    {:ok, user, _codes} =
      Auth.register_user(%{
        "username" => "newcomer_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "terms_accepted" => "true"
      })

    assert user.status == "pending"

    assert Repo.exists?(
             from(n in NotificationSchema,
               where:
                 n.user_id == ^admin.id and n.type == "pending_registration" and
                   n.actor_user_id == ^user.id
             )
           )
  end

  defp user(role_name, status) do
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

    Repo.update_all(from(u in Setup.User, where: u.id == ^user.id), set: [status: status])
    Repo.get!(Setup.User, user.id) |> Repo.preload(:role)
  end
end
