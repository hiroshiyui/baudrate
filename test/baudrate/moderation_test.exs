defmodule Baudrate.ModerationTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Moderation
  alias Baudrate.Moderation.Report
  alias Baudrate.Federation.{KeyStore, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    user = create_user()
    remote_actor = create_remote_actor()

    %{user: user, remote_actor: remote_actor}
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "mod_user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp create_remote_actor do
    uid = System.unique_integer([:positive])

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/actor-#{uid}",
        username: "actor_#{uid}",
        domain: "remote.example",
        public_key_pem: elem(KeyStore.generate_keypair(), 0),
        inbox: "https://remote.example/users/actor-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    actor
  end

  describe "create_report/1" do
    test "creates a report targeting a remote actor", %{remote_actor: actor} do
      assert {:ok, %Report{} = report} =
               Moderation.create_report(%{
                 reason: "Spam content",
                 remote_actor_id: actor.id
               })

      assert report.reason == "Spam content"
      assert report.status == "open"
      assert report.remote_actor_id == actor.id
    end

    test "fails without a reason", %{remote_actor: actor} do
      assert {:error, changeset} =
               Moderation.create_report(%{remote_actor_id: actor.id})

      assert errors_on(changeset).reason
    end

    test "fails without any target" do
      assert {:error, changeset} =
               Moderation.create_report(%{reason: "No target"})

      assert errors_on(changeset).base
    end

    test "validates reason length", %{remote_actor: actor} do
      assert {:error, changeset} =
               Moderation.create_report(%{
                 reason: String.duplicate("x", 2001),
                 remote_actor_id: actor.id
               })

      assert errors_on(changeset).reason
    end
  end

  describe "list_reports/1" do
    test "returns open reports by default", %{remote_actor: actor} do
      {:ok, _} = Moderation.create_report(%{reason: "Open report", remote_actor_id: actor.id})

      reports = Moderation.list_reports()
      assert length(reports) == 1
      assert hd(reports).reason == "Open report"
    end

    test "filters by status", %{user: user, remote_actor: actor} do
      {:ok, report} =
        Moderation.create_report(%{reason: "To resolve", remote_actor_id: actor.id})

      {:ok, _} = Moderation.resolve_report(report, user.id, "Done")

      assert Moderation.list_reports(status: "open") == []
      assert length(Moderation.list_reports(status: "resolved")) == 1
    end
  end

  describe "get_report!/1" do
    test "returns report with preloads", %{remote_actor: actor} do
      {:ok, report} =
        Moderation.create_report(%{reason: "Test", remote_actor_id: actor.id})

      fetched = Moderation.get_report!(report.id)
      assert fetched.id == report.id
      assert fetched.remote_actor.id == actor.id
    end

    test "raises for nonexistent ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Moderation.get_report!(0)
      end
    end
  end

  describe "resolve_report/3" do
    test "resolves with note", %{user: user, remote_actor: actor} do
      {:ok, report} =
        Moderation.create_report(%{reason: "Issue", remote_actor_id: actor.id})

      assert {:ok, resolved} = Moderation.resolve_report(report, user.id, "Addressed")
      assert resolved.status == "resolved"
      assert resolved.resolved_by_id == user.id
      assert resolved.resolution_note == "Addressed"
      assert resolved.resolved_at
    end

    test "resolves without note", %{user: user, remote_actor: actor} do
      {:ok, report} =
        Moderation.create_report(%{reason: "Issue", remote_actor_id: actor.id})

      assert {:ok, resolved} = Moderation.resolve_report(report, user.id)
      assert resolved.status == "resolved"
      assert is_nil(resolved.resolution_note)
    end
  end

  describe "dismiss_report/2" do
    test "dismisses a report", %{user: user, remote_actor: actor} do
      {:ok, report} =
        Moderation.create_report(%{reason: "False alarm", remote_actor_id: actor.id})

      assert {:ok, dismissed} = Moderation.dismiss_report(report, user.id)
      assert dismissed.status == "dismissed"
      assert dismissed.resolved_by_id == user.id
      assert dismissed.resolved_at
    end
  end

  describe "open_report_count/0" do
    test "returns zero when no reports" do
      assert Moderation.open_report_count() == 0
    end

    test "counts only open reports", %{user: user, remote_actor: actor} do
      {:ok, r1} = Moderation.create_report(%{reason: "One", remote_actor_id: actor.id})
      {:ok, _r2} = Moderation.create_report(%{reason: "Two", remote_actor_id: actor.id})
      {:ok, _} = Moderation.resolve_report(r1, user.id)

      assert Moderation.open_report_count() == 1
    end
  end
end
