defmodule Baudrate.Auth.UserMuteTest do
  use Baudrate.DataCase

  alias Baudrate.Auth.UserMute
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name) do
    role = Repo.one!(from r in Role, where: r.name == ^role_name)

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  describe "local_changeset/2" do
    test "valid changeset for muting a local user" do
      user = create_user("user")
      target = create_user("user")

      changeset =
        UserMute.local_changeset(%UserMute{}, %{
          user_id: user.id,
          muted_user_id: target.id
        })

      assert changeset.valid?
    end

    test "rejects self-mute" do
      user = create_user("user")

      changeset =
        UserMute.local_changeset(%UserMute{}, %{
          user_id: user.id,
          muted_user_id: user.id
        })

      refute changeset.valid?
      assert %{muted_user_id: ["cannot mute yourself"]} = errors_on(changeset)
    end

    test "requires user_id and muted_user_id" do
      changeset = UserMute.local_changeset(%UserMute{}, %{})
      refute changeset.valid?
      assert %{user_id: _, muted_user_id: _} = errors_on(changeset)
    end
  end

  describe "remote_changeset/2" do
    test "valid changeset for muting a remote actor" do
      user = create_user("user")

      changeset =
        UserMute.remote_changeset(%UserMute{}, %{
          user_id: user.id,
          muted_actor_ap_id: "https://remote.example/users/someone"
        })

      assert changeset.valid?
    end

    test "requires user_id and muted_actor_ap_id" do
      changeset = UserMute.remote_changeset(%UserMute{}, %{})
      refute changeset.valid?
      assert %{user_id: _, muted_actor_ap_id: _} = errors_on(changeset)
    end
  end
end
