defmodule Baudrate.Auth.SessionCleanerTest do
  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Auth.{SessionCleaner, UserSession}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    role = Repo.one!(from r in Baudrate.Setup.Role, where: r.name == "user")

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "cleaner_user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    %{user: user}
  end

  describe "GenServer lifecycle" do
    test "is started by the application supervision tree" do
      pid = Process.whereis(SessionCleaner)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "purge_expired_sessions/0" do
    test "deletes expired sessions", %{user: user} do
      {:ok, _token, _refresh} = Auth.create_user_session(user.id)

      # Manually expire the session
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      from(s in UserSession, where: s.user_id == ^user.id)
      |> Repo.update_all(set: [expires_at: past])

      count_before = Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count)
      assert count_before == 1

      Auth.purge_expired_sessions()

      count_after = Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count)
      assert count_after == 0
    end

    test "does not delete non-expired sessions", %{user: user} do
      {:ok, _token, _refresh} = Auth.create_user_session(user.id)

      count_before = Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count)
      assert count_before == 1

      Auth.purge_expired_sessions()

      count_after = Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count)
      assert count_after == 1
    end
  end

  describe "handle_info :cleanup" do
    test "triggers purge_expired_sessions", %{user: user} do
      {:ok, _token, _refresh} = Auth.create_user_session(user.id)

      # Manually expire the session
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      from(s in UserSession, where: s.user_id == ^user.id)
      |> Repo.update_all(set: [expires_at: past])

      # Send :cleanup to the running SessionCleaner process
      send(Process.whereis(SessionCleaner), :cleanup)
      # Give it a moment to process
      :timer.sleep(100)

      count = Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count)
      assert count == 0
    end
  end
end
