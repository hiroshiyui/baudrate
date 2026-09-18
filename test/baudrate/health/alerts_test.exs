defmodule Baudrate.Health.AlertsTest do
  @moduledoc """
  The acceptance gate for ADR 0044: a failing check reaches a person, and a
  working instance stays quiet.

  Both halves matter equally. An alert that never fires is the state Phase 2A
  was opened to fix; an alert that fires every hour is one an operator learns
  to ignore, which is the same thing a week later.
  """

  use Baudrate.DataCase, async: true

  import Ecto.Query

  alias Baudrate.Health.Alerts
  alias Baudrate.Notification.Notification
  alias Baudrate.Repo
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    %{admin: user("admin"), moderator: user("moderator"), member: user("user")}
  end

  describe "a failing check" do
    test "says nothing on the first poll it is seen", %{admin: admin} do
      state = Alerts.run(Alerts.initial_state(), report: failing(["backup"]))

      assert state == %{checks: ["backup"], consecutive: 1}
      assert notifications(admin.id) == []
    end

    test "tells every admin on the second consecutive poll", %{admin: admin} do
      state =
        Alerts.initial_state()
        |> Alerts.run(report: failing(["backup"]))
        |> Alerts.run(report: failing(["backup"]))

      assert state == %{checks: ["backup"], consecutive: 2}

      assert [%{type: "health_alert", data: %{"checks" => ["backup"]}}] =
               notifications(admin.id)
    end

    test "tells nobody but the admins", %{moderator: mod, member: member} do
      poll_twice(["backup"])

      assert notifications(mod.id) == []
      assert notifications(member.id) == []
    end

    test "names every failing check, sorted", %{admin: admin} do
      poll_twice(["disk", "backup"])

      assert [%{data: %{"checks" => ["backup", "disk"]}}] = notifications(admin.id)
    end

    test "a skipped check is not a failure", %{admin: admin} do
      report = %{
        status: :ok,
        checks: %{
          backup: %{status: :skipped, reason: "no backup directory is configured"},
          disk: %{status: :ok}
        }
      }

      state = Alerts.run(Alerts.initial_state(), report: report)

      assert state == Alerts.initial_state()
      assert notifications(admin.id) == []
    end
  end

  describe "not nagging" do
    test "does not repeat the same failing set the next hour", %{admin: admin} do
      state = poll_twice(["backup"])
      Alerts.run(state, report: failing(["backup"]))

      assert length(notifications(admin.id)) == 1
    end

    test "repeats it a day later", %{admin: admin} do
      state = poll_twice(["backup"])
      age_notifications(hours: 25)

      Alerts.run(state, report: failing(["backup"]))

      assert length(notifications(admin.id)) == 2
    end

    test "a set that changes restarts the count before it is announced", %{admin: admin} do
      state = poll_twice(["backup"])

      # `disk` joins the set: it has been seen once, so nothing is sent yet.
      state = Alerts.run(state, report: failing(["backup", "disk"]))
      assert state == %{checks: ["backup", "disk"], consecutive: 1}
      assert length(notifications(admin.id)) == 1

      # Seen twice now, and it is new information, so it goes out at once
      # rather than waiting for the daily repeat.
      Alerts.run(state, report: failing(["backup", "disk"]))

      assert [%{data: %{"checks" => ["backup", "disk"]}}, %{data: %{"checks" => ["backup"]}}] =
               notifications(admin.id)
    end
  end

  describe "recovery" do
    test "is announced once after an alert", %{admin: admin} do
      state = poll_twice(["backup"])

      state = Alerts.run(state, report: all_ok())
      assert state == Alerts.initial_state()
      assert [%{type: "health_recovered"} | _] = notifications(admin.id)

      # A second healthy poll says nothing more.
      Alerts.run(state, report: all_ok())
      assert length(notifications(admin.id)) == 2
    end

    test "is not announced when nothing was ever wrong", %{admin: admin} do
      Alerts.run(Alerts.initial_state(), report: all_ok())

      assert notifications(admin.id) == []
    end

    test "is not announced for a failure that never reached anyone", %{admin: admin} do
      # One failing poll, then healthy: the debounce means nobody was told
      # there was a problem, so nobody is told it went away.
      state = Alerts.run(Alerts.initial_state(), report: failing(["backup"]))
      Alerts.run(state, report: all_ok())

      assert notifications(admin.id) == []
    end
  end

  describe "restarting" do
    test "does not re-announce a problem already reported", %{admin: admin} do
      poll_twice(["backup"])

      # A deploy restarts SessionCleaner, so the consecutive counter is lost
      # but the notification rows are not. Two fresh polls must not produce a
      # second alert about the same thing.
      state =
        Alerts.initial_state()
        |> Alerts.run(report: failing(["backup"]))
        |> Alerts.run(report: failing(["backup"]))

      assert state.consecutive == 2
      assert length(notifications(admin.id)) == 1
    end
  end

  test "the operational notices cannot be switched off in preferences" do
    always = Notification.always_delivered_types()

    assert "health_alert" in always
    assert "health_recovered" in always
    refute "health_alert" in Notification.configurable_types()
  end

  # --- helpers ---

  defp poll_twice(checks) do
    Alerts.initial_state()
    |> Alerts.run(report: failing(checks))
    |> Alerts.run(report: failing(checks))
  end

  defp failing(names) do
    checks =
      Map.new(names, fn name ->
        {String.to_existing_atom(name), %{status: :fail, reason: "#{name} is unhappy"}}
      end)

    %{status: :fail, checks: Map.put_new(checks, :database, %{status: :ok})}
  end

  defp all_ok do
    %{status: :ok, checks: %{database: %{status: :ok}, backup: %{status: :ok}}}
  end

  defp notifications(user_id) do
    from(n in Notification,
      where: n.user_id == ^user_id,
      order_by: [desc: n.inserted_at, desc: n.id]
    )
    |> Repo.all()
  end

  # Ages every notification so the daily repeat is due. Explicit timestamps,
  # never a sleep.
  defp age_notifications(hours: hours) do
    at = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)
    Repo.update_all(Notification, set: [inserted_at: at])
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
    Repo.get!(Setup.User, user.id)
  end
end
