defmodule Baudrate.Auth.UserBlockTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Auth.UserBlock

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(username \\ nil) do
    username = username || "user_#{System.unique_integer([:positive])}"
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => username,
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  describe "local_changeset/2" do
    test "creates a valid changeset for blocking a local user" do
      user = create_user()
      target = create_user()

      changeset =
        UserBlock.local_changeset(%UserBlock{}, %{
          user_id: user.id,
          blocked_user_id: target.id
        })

      assert changeset.valid?
    end

    test "rejects self-block" do
      user = create_user()

      changeset =
        UserBlock.local_changeset(%UserBlock{}, %{
          user_id: user.id,
          blocked_user_id: user.id
        })

      refute changeset.valid?
      assert {"cannot block yourself", _} = changeset.errors[:blocked_user_id]
    end

    test "requires user_id and blocked_user_id" do
      changeset = UserBlock.local_changeset(%UserBlock{}, %{})
      refute changeset.valid?
      assert changeset.errors[:user_id]
      assert changeset.errors[:blocked_user_id]
    end
  end

  describe "remote_changeset/2" do
    test "creates a valid changeset for blocking a remote actor" do
      user = create_user()

      changeset =
        UserBlock.remote_changeset(%UserBlock{}, %{
          user_id: user.id,
          blocked_actor_ap_id: "https://remote.example/users/someone"
        })

      assert changeset.valid?
    end

    test "requires user_id and blocked_actor_ap_id" do
      changeset = UserBlock.remote_changeset(%UserBlock{}, %{})
      refute changeset.valid?
      assert changeset.errors[:user_id]
      assert changeset.errors[:blocked_actor_ap_id]
    end
  end
end
