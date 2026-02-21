defmodule Baudrate.ModerationLogTest do
  use Baudrate.DataCase

  alias Baudrate.Moderation

  setup do
    user = setup_user("admin")
    {:ok, user: user}
  end

  describe "log_action/3" do
    test "creates a moderation log entry", %{user: user} do
      assert {:ok, log} =
               Moderation.log_action(user.id, "ban_user",
                 target_type: "user",
                 target_id: 42,
                 details: %{"username" => "baduser", "reason" => "spam"}
               )

      assert log.action == "ban_user"
      assert log.actor_id == user.id
      assert log.target_type == "user"
      assert log.target_id == 42
      assert log.details["username"] == "baduser"
    end

    test "creates a log without optional fields", %{user: user} do
      assert {:ok, log} = Moderation.log_action(user.id, "create_board")
      assert log.action == "create_board"
      assert log.target_type == nil
      assert log.details == %{}
    end
  end

  describe "list_moderation_logs/1" do
    test "returns logs ordered by newest first", %{user: user} do
      Moderation.log_action(user.id, "ban_user", details: %{"order" => "first"})
      Moderation.log_action(user.id, "unban_user", details: %{"order" => "second"})

      %{logs: logs, page: 1, total_pages: 1} = Moderation.list_moderation_logs()
      assert length(logs) == 2
      assert hd(logs).action == "unban_user"
    end

    test "filters by action", %{user: user} do
      Moderation.log_action(user.id, "ban_user")
      Moderation.log_action(user.id, "create_board")

      %{logs: logs} = Moderation.list_moderation_logs(action: "ban_user")
      assert length(logs) == 1
      assert hd(logs).action == "ban_user"
    end

    test "paginates results", %{user: user} do
      for _ <- 1..30, do: Moderation.log_action(user.id, "ban_user")

      %{logs: logs, page: 1, total_pages: 2} = Moderation.list_moderation_logs(page: 1)
      assert length(logs) == 25

      %{logs: logs, page: 2, total_pages: 2} = Moderation.list_moderation_logs(page: 2)
      assert length(logs) == 5
    end

    test "preloads actor", %{user: user} do
      Moderation.log_action(user.id, "ban_user")

      %{logs: [log]} = Moderation.list_moderation_logs()
      assert log.actor.username == user.username
    end
  end

  defp setup_user(role_name) do
    import Ecto.Query
    alias Baudrate.Repo
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "test_#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end
end
