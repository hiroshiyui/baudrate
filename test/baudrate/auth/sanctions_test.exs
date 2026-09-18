defmodule Baudrate.Auth.SanctionsTest do
  @moduledoc """
  Issuing and lifting sanctions (ADR 0029): who may do it, what it does to the
  account, and what the member is told.
  """

  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Auth.Sanction
  alias Baudrate.Moderation
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Repo
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()

    %{
      admin: user("admin"),
      moderator: user("moderator"),
      member: user("user"),
      other_moderator: user("moderator")
    }
  end

  describe "authority" do
    test "a moderator may sanction a member", %{moderator: mod, member: member} do
      assert Auth.authorize_sanction(mod, member, "silence") == :ok
    end

    test "nobody sanctions themselves", %{moderator: mod} do
      assert Auth.issue_sanction(mod, mod, "warn") == {:error, :self_action}
    end

    test "a moderator cannot sanction another moderator or an admin", %{
      moderator: mod,
      other_moderator: peer,
      admin: admin
    } do
      assert Auth.issue_sanction(mod, peer, "silence") == {:error, :role_too_high}
      assert Auth.issue_sanction(mod, admin, "silence") == {:error, :role_too_high}
    end

    test "an ordinary member cannot sanction anyone", %{member: member} do
      target = user("user")
      assert Auth.issue_sanction(member, target, "warn") == {:error, :unauthorized}
    end

    test "a banned account is not sanctioned further", %{moderator: mod, member: member} do
      Repo.update_all(from(u in Setup.User, where: u.id == ^member.id), set: [status: "banned"])
      member = reload(member)

      assert Auth.issue_sanction(mod, member, "silence") == {:error, :cannot_sanction_banned}
    end
  end

  # A ban is harsher than every sanction above, and until this release it was
  # the one rung of the ladder that checked neither the permission nor the rank
  # rule — only self-ban. So a moderator could not silence a peer for an hour,
  # while `ban_user/3` would permanently ban an admin for any caller.
  describe "banning authority" do
    test "an admin may ban a member", %{admin: admin, member: member} do
      assert {:ok, banned, _revoked} = Auth.ban_user(member, admin)
      assert banned.status == "banned"
    end

    test "nobody bans themselves", %{admin: admin} do
      assert Auth.ban_user(admin, admin) == {:error, :self_action}
    end

    test "a moderator cannot ban, though it may silence", %{moderator: mod, member: member} do
      assert Auth.ban_user(member, mod) == {:error, :unauthorized}
      assert Auth.authorize_sanction(mod, member, "silence") == :ok
    end

    test "an ordinary member cannot ban", %{member: member} do
      assert Auth.ban_user(user("user"), member) == {:error, :unauthorized}
    end

    # The rank rule that every other sanction already applied. Banning a peer
    # admin is now demote-then-ban: two deliberate acts rather than one.
    test "an admin cannot ban another admin", %{admin: admin} do
      assert Auth.ban_user(user("admin"), admin) == {:error, :role_too_high}
    end

    test "an admin may unban", %{admin: admin, member: member} do
      {:ok, banned, _} = Auth.ban_user(member, admin)
      assert {:ok, restored} = Auth.unban_user(banned, admin)
      assert restored.status == "active"
    end

    test "a moderator cannot unban", %{admin: admin, moderator: mod, member: member} do
      {:ok, banned, _} = Auth.ban_user(member, admin)
      assert Auth.unban_user(banned, mod) == {:error, :unauthorized}
    end

    # Deliberately no rank rule on the way back: an account is demoted before
    # it can be banned, so re-checking rank here would leave a banned admin
    # unrestorable through the UI.
    test "unbanning is not refused on rank", %{admin: admin} do
      peer = user("admin")
      Repo.update_all(from(u in Setup.User, where: u.id == ^peer.id), set: [status: "banned"])

      assert {:ok, restored} = Auth.unban_user(reload(peer), admin)
      assert restored.status == "active"
    end
  end

  describe "the duration cap" do
    test "a moderator is capped at 30 days", %{moderator: mod, member: member} do
      assert {:error, :duration_too_long} =
               Auth.issue_sanction(mod, member, "silence", expires_at: days_from_now(31))

      assert {:ok, _} = Auth.issue_sanction(mod, member, "silence", expires_at: days_from_now(29))
    end

    test "a moderator cannot issue an indefinite silence", %{moderator: mod, member: member} do
      assert Auth.issue_sanction(mod, member, "silence") == {:error, :duration_too_long}
    end

    test "an admin can, and has no cap", %{admin: admin, member: member} do
      assert Auth.max_sanction_expiry(admin) == nil
      assert {:ok, %Sanction{expires_at: nil}} = Auth.issue_sanction(admin, member, "silence")
    end

    test "a warning takes no duration at all", %{moderator: mod, member: member} do
      assert {:ok, %Sanction{expires_at: nil}} =
               Auth.issue_sanction(mod, member, "warn",
                 reason: "Keep it civil",
                 expires_at: days_from_now(7)
               )
    end
  end

  describe "warn" do
    test "restricts nothing, and demands no acknowledgement", %{moderator: mod, member: member} do
      assert {:ok, sanction} = Auth.issue_sanction(mod, member, "warn", reason: "Keep it civil")

      assert sanction.kind == "warn"
      assert Auth.ensure_can_interact(member) == :ok
      assert Auth.active_sanctions(member) == []
      assert [%Sanction{kind: "warn"}] = Auth.list_sanctions(member)
    end

    test "tells the member and records the action", %{moderator: mod, member: member} do
      {:ok, _} = Auth.issue_sanction(mod, member, "warn", reason: "Keep it civil")

      assert notice = notification(member, "sanction_applied")
      assert notice.data["kind"] == "warn"
      assert notice.data["reason"] == "Keep it civil"

      assert logged?(mod, "warn_user", member)
    end
  end

  describe "silence" do
    test "makes the account read-only until it ends", %{admin: admin, member: member} do
      {:ok, _} = Auth.issue_sanction(admin, member, "silence", expires_at: days_from_now(1))

      assert Auth.ensure_can_interact(member) == {:error, :account_silenced}
      assert Auth.silenced?(member)
      refute Auth.suspended?(member)
    end

    test "leaves the sessions alone: a silenced member can still read and report", %{
      admin: admin,
      member: member
    } do
      {:ok, _token, _refresh} = Auth.create_user_session(member.id)
      {:ok, _} = Auth.issue_sanction(admin, member, "silence")

      assert Repo.exists?(from(s in Baudrate.Auth.UserSession, where: s.user_id == ^member.id))
    end
  end

  describe "suspend" do
    test "requires an end date", %{admin: admin, member: member} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Auth.issue_sanction(admin, member, "suspend")

      assert "can't be blank" in errors_on(changeset).expires_at
    end

    test "refuses sign-in and says why", %{admin: admin, member: member} do
      {:ok, _} =
        Auth.issue_sanction(admin, member, "suspend",
          reason: "Three removals this week",
          expires_at: days_from_now(3)
        )

      assert {:error, {:suspended, sanction}} =
               Auth.authenticate_by_password(member.username, "Password123!x")

      assert sanction.reason == "Three removals this week"
    end

    test "revokes open sessions and cancels exports and moves", %{
      admin: admin,
      member: member
    } do
      {:ok, _token, _refresh} = Auth.create_user_session(member.id)

      {:ok, _} = Auth.issue_sanction(admin, member, "suspend", expires_at: days_from_now(3))

      refute Repo.exists?(from(s in Baudrate.Auth.UserSession, where: s.user_id == ^member.id))
    end

    test "leaves invite codes alone — they expire by themselves", %{
      admin: admin,
      member: member
    } do
      member = age_account(member)
      {:ok, invite} = Auth.generate_invite_code(member)

      {:ok, _} = Auth.issue_sanction(admin, member, "suspend", expires_at: days_from_now(3))

      refute Repo.get!(Baudrate.Auth.InviteCode, invite.id).revoked
    end

    test "lets sign-in through again once it has run out", %{admin: admin, member: member} do
      {:ok, sanction} =
        Auth.issue_sanction(admin, member, "suspend", expires_at: days_from_now(1))

      # No sweep runs: the sanction simply stops being active.
      expire(sanction)

      assert {:ok, _user} = Auth.authenticate_by_password(member.username, "Password123!x")
      assert Auth.ensure_can_interact(member) == :ok
    end
  end

  describe "lift" do
    test "clears every active row of that kind, and says who and why", %{
      admin: admin,
      member: member
    } do
      {:ok, _} = Auth.issue_sanction(admin, member, "silence", expires_at: days_from_now(1))
      {:ok, _} = Auth.issue_sanction(admin, member, "silence", expires_at: days_from_now(5))

      assert {:ok, 2} = Auth.lift_sanction(admin, member, "silence", lift_reason: "Apologised")

      assert Auth.ensure_can_interact(member) == :ok

      for sanction <- Auth.list_sanctions(member) do
        assert sanction.lifted_by_id == admin.id
        assert sanction.lift_reason == "Apologised"
      end

      assert notification(member, "sanction_lifted")
      assert logged?(admin, "lift_sanction", member)
    end

    test "is how a sanction is shortened, since issuing only extends", %{
      admin: admin,
      member: member
    } do
      {:ok, _} = Auth.issue_sanction(admin, member, "silence", expires_at: days_from_now(30))
      {:ok, _} = Auth.issue_sanction(admin, member, "silence", expires_at: days_from_now(1))

      # Still silenced for thirty days: the shorter row did not shorten anything.
      assert %Sanction{} = active = Auth.active_sanction(member, "silence")
      assert DateTime.diff(active.expires_at, DateTime.utc_now()) > 29 * 24 * 60 * 60

      assert {:ok, 2} = Auth.lift_sanction(admin, member, "silence")
      assert Auth.ensure_can_interact(member) == :ok
    end

    test "says nothing when there was nothing active", %{admin: admin, member: member} do
      assert {:ok, 0} = Auth.lift_sanction(admin, member, "silence")
      refute notification(member, "sanction_lifted")
    end

    test "a moderator cannot lift a sanction on an admin", %{moderator: mod, admin: admin} do
      assert Auth.lift_sanction(mod, admin, "silence") == {:error, :role_too_high}
    end
  end

  describe "the ended notice" do
    test "tells the member once, and only after the sanction ran out", %{
      admin: admin,
      member: member
    } do
      {:ok, sanction} =
        Auth.issue_sanction(admin, member, "silence", expires_at: days_from_now(1))

      assert Auth.notify_ended_sanctions() == 0
      refute notification(member, "sanction_ended")

      expire(sanction)

      assert Auth.notify_ended_sanctions() == 1
      assert notification(member, "sanction_ended")

      # A second run tells nobody twice.
      assert Auth.notify_ended_sanctions() == 0
    end

    test "a lifted sanction gets no 'it has ended' notice", %{admin: admin, member: member} do
      {:ok, sanction} =
        Auth.issue_sanction(admin, member, "silence", expires_at: days_from_now(1))

      {:ok, 1} = Auth.lift_sanction(admin, member, "silence")
      expire(sanction)

      assert Auth.notify_ended_sanctions() == 0
    end
  end

  test "sanctions are never deleted, only lifted", %{admin: admin, member: member} do
    {:ok, _} = Auth.issue_sanction(admin, member, "warn", reason: "First")
    {:ok, _} = Auth.issue_sanction(admin, member, "silence", expires_at: days_from_now(1))
    {:ok, _} = Auth.lift_sanction(admin, member, "silence")

    assert length(Auth.list_sanctions(member)) == 2
  end

  # --- helpers ---

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
    reload(user)
  end

  defp reload(user), do: Repo.get!(Setup.User, user.id) |> Repo.preload(:role)

  # Invites need an account at least seven days old.
  defp age_account(user) do
    at =
      DateTime.utc_now()
      |> DateTime.add(-30 * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    Repo.update_all(from(u in Setup.User, where: u.id == ^user.id), set: [inserted_at: at])
    reload(user)
  end

  # Moves a sanction's end into the past without going through the changeset,
  # which rightly refuses to create one that has already ended.
  defp expire(%Sanction{id: id}) do
    at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(s in Sanction, where: s.id == ^id), set: [expires_at: at])
  end

  defp days_from_now(days) do
    DateTime.utc_now() |> DateTime.add(days * 24 * 60 * 60, :second) |> DateTime.truncate(:second)
  end

  defp notification(user, type) do
    Repo.one(
      from(n in NotificationSchema,
        where: n.user_id == ^user.id and n.type == ^type,
        order_by: [desc: n.id],
        limit: 1
      )
    )
  end

  defp logged?(actor, action, target) do
    Repo.exists?(
      from(l in Moderation.Log,
        where:
          l.actor_id == ^actor.id and l.action == ^action and l.target_type == "user" and
            l.target_id == ^target.id
      )
    )
  end
end
