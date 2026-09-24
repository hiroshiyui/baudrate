defmodule Baudrate.AnnouncementsTest do
  use Baudrate.DataCase, async: true

  import BaudrateWeb.ConnCase, only: [setup_user: 1, setup_user: 2]

  alias Baudrate.Announcements
  alias Baudrate.Announcements.Announcement
  alias Baudrate.Notification.Notification

  defp announce(admin, body, attrs \\ %{}) do
    {:ok, a} = Announcements.create_announcement(admin, Map.put(attrs, "body", body))
    a
  end

  defp backdate(announcement, days) do
    at = DateTime.utc_now(:second) |> DateTime.add(-days, :day)

    Repo.update_all(from(a in Announcement, where: a.id == ^announcement.id),
      set: [inserted_at: at]
    )
  end

  setup do
    %{admin: setup_user("admin"), member: setup_user("user")}
  end

  describe "create_announcement/3" do
    test "only an admin may post one", %{admin: admin, member: member} do
      moderator = setup_user("moderator")

      assert {:ok, %Announcement{created_by_id: id}} =
               Announcements.create_announcement(admin, %{"body" => " Maintenance tonight "})

      assert id == admin.id

      for who <- [member, moderator] do
        assert {:error, :unauthorized} =
                 Announcements.create_announcement(who, %{"body" => "Mine"})
      end
    end

    test "needs text, at most 500 characters, and an end in the future", %{admin: admin} do
      assert {:error, %Ecto.Changeset{}} =
               Announcements.create_announcement(admin, %{"body" => "  "})

      assert {:error, %Ecto.Changeset{}} =
               Announcements.create_announcement(admin, %{"body" => String.duplicate("x", 501)})

      past = DateTime.utc_now(:second) |> DateTime.add(-60)

      assert {:error, %Ecto.Changeset{} = cs} =
               Announcements.create_announcement(admin, %{"body" => "Late", "ends_at" => past})

      assert "must be in the future" in errors_on(cs).ends_at
    end

    test "notify sends it to active members only", %{admin: admin, member: member} do
      bot = setup_user("user") |> Ecto.Changeset.change(is_bot: true) |> Repo.update!()
      pending = setup_user("user", %{status: "pending"})
      banned = setup_user("user", %{status: "banned"})
      deleted = setup_user("user") |> Ecto.Changeset.change(status: "deleted") |> Repo.update!()

      {:ok, a} =
        Announcements.create_announcement(admin, %{"body" => "Hello all"}, notify: true)

      recipients =
        Repo.all(
          from(n in Notification, where: n.type == "admin_announcement", select: n.user_id)
        )

      assert member.id in recipients

      for nobody <- [bot, pending, banned, deleted, admin] do
        refute nobody.id in recipients
      end

      assert [%{data: %{"announcement_id" => id, "message" => "Hello all"}} | _] =
               Repo.all(from(n in Notification, where: n.user_id == ^member.id))

      assert id == a.id
    end

    test "without notify, no notification is sent", %{admin: admin} do
      announce(admin, "Quiet")
      refute Repo.exists?(from(n in Notification, where: n.type == "admin_announcement"))
    end
  end

  describe "active_for/1" do
    test "shows live ones newest first, at most three, to guests and members", ctx do
      old = announce(ctx.admin, "Old")
      backdate(old, 3)
      ids = for n <- 1..3, do: announce(ctx.admin, "New #{n}").id

      for viewer <- [nil, ctx.member] do
        assert Enum.map(Announcements.active_for(viewer), & &1.id) == Enum.reverse(ids)
      end
    end

    test "leaves out ended ones", %{admin: admin} do
      a = announce(admin, "Soon over")
      {:ok, _} = Announcements.end_announcement(admin, a.id)

      assert Announcements.active_for(nil) == []
    end

    test "a member's dismissal holds for them and nobody else", ctx do
      a = announce(ctx.admin, "Read me")
      other = setup_user("user")

      assert :ok = Announcements.dismiss(ctx.member, a.id)
      assert :ok = Announcements.dismiss(ctx.member, a.id)
      assert :ok = Announcements.dismiss(ctx.member, -1)

      assert Announcements.active_for(ctx.member) == []
      assert [%{id: id}] = Announcements.active_for(other)
      assert id == a.id
      assert [_] = Announcements.active_for(nil)
    end
  end

  describe "end_announcement/2" do
    test "ends a live one once; only an admin may", %{admin: admin, member: member} do
      a = announce(admin, "Ending")

      assert {:error, :unauthorized} = Announcements.end_announcement(member, a.id)
      assert {:ok, %{ends_at: %DateTime{}}} = Announcements.end_announcement(admin, a.id)
      assert {:error, :not_found} = Announcements.end_announcement(admin, a.id)
      assert {:error, :not_found} = Announcements.end_announcement(admin, -1)
    end
  end
end
