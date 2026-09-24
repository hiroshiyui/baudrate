defmodule Baudrate.DashboardTest do
  use Baudrate.DataCase, async: true

  import BaudrateWeb.ConnCase, only: [setup_user: 1, setup_user: 2]

  alias Baudrate.Dashboard
  alias Baudrate.Federation.{DeliveryJob, Discovery, DomainBlocks, KeyStore, RemoteActor}
  alias Baudrate.Moderation
  alias Baudrate.Moderation.HeldPosts

  defp remote_actor(domain) do
    uid = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://#{domain}/users/r#{uid}",
      username: "r#{uid}",
      domain: domain,
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://#{domain}/users/r#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now(:second)
    })
    |> Repo.insert!()
  end

  defp set(user, fields), do: user |> Ecto.Changeset.change(fields) |> Repo.update!()

  describe "members/1" do
    test "counts the accounts NodeInfo counts, and when they joined and were last here" do
      today = Date.utc_today()
      old = DateTime.utc_now(:second) |> DateTime.add(-60, :day)

      recent = setup_user("user")
      set(recent, last_active_on: today)
      _month_old = setup_user("user") |> set(inserted_at: DateTime.add(old, 45, :day))
      _veteran = setup_user("user") |> set(inserted_at: old)

      # None of these is a member.
      setup_user("user") |> set(is_bot: true)
      setup_user("user", %{status: "banned"})
      setup_user("user") |> set(status: "deleted")

      members = Dashboard.members(today)

      assert members.total == 3
      assert members.total == Discovery.nodeinfo()["usage"]["users"]["total"]
      assert members.active_month == 1
      assert members.new_week == 1
      assert members.new_month == 2
    end
  end

  describe "moderation/1" do
    test "counts open reports, held posts the reviewer could approve, and pending registrations" do
      admin = setup_user("admin")
      actor = remote_actor("reported.example")

      {:ok, _} = Moderation.create_report(%{reason: "Spam", remote_actor_id: actor.id})
      {:ok, closed} = Moderation.create_report(%{reason: "Old", remote_actor_id: actor.id})
      Moderation.dismiss_report(closed, admin.id)

      author = setup_user("user")

      {:ok, _} =
        HeldPosts.hold_article(
          %{"title" => "Held", "body" => "b", "slug" => "held-dash", "user_id" => author.id},
          [],
          [],
          "first_posts",
          nil
        )

      setup_user("user", %{status: "pending"})
      setup_user("user", %{status: "pending"}) |> set(is_bot: true)

      assert %{open_reports: 1, held_posts: 1, pending_registrations: 1} =
               Dashboard.moderation(admin)
    end
  end

  describe "federation/0" do
    test "counts failed deliveries, blocked domains and suspended accounts" do
      admin = setup_user("admin")

      for {status, n} <- [{"failed", 1}, {"pending", 2}] do
        {:ok, job} =
          DeliveryJob.create_changeset(%{
            activity_json: ~s({"id":"#{status}-#{n}"}),
            inbox_url: "https://peer.example/inbox",
            actor_uri: "https://local.example/ap/users/a#{n}"
          })
          |> Repo.insert()

        job |> Ecto.Changeset.change(status: status) |> Repo.update!()
      end

      {:ok, _} = DomainBlocks.block_domain("blocked.example", admin, %{reason: "spam"})
      remote_actor("suspended.example") |> set(suspended_at: DateTime.utc_now(:second))
      remote_actor("fine.example")

      assert %{failed_deliveries: 1, blocked_domains: 1, suspended_actors: 1} =
               Dashboard.federation()
    end
  end

  test "names no account, board or remote domain" do
    admin = setup_user("admin")

    for figures <- [Dashboard.members(), Dashboard.moderation(admin), Dashboard.federation()] do
      assert Enum.all?(Map.values(figures), &is_integer/1)
    end
  end
end
