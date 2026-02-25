defmodule Baudrate.Federation.UserFollowTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.{RemoteActor, UserFollow}

  defp create_user do
    import Ecto.Query

    unless Repo.exists?(from(r in Baudrate.Setup.Role, where: r.name == "admin")) do
      Baudrate.Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "uf_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/actor-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    actor
  end

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      user = create_user()
      remote_actor = create_remote_actor()

      changeset =
        UserFollow.changeset(%UserFollow{}, %{
          user_id: user.id,
          remote_actor_id: remote_actor.id,
          state: "pending",
          ap_id: "https://local.example/ap/users/alice#follow-1"
        })

      assert changeset.valid?
    end

    test "valid changeset with optional accepted_at" do
      user = create_user()
      remote_actor = create_remote_actor()

      changeset =
        UserFollow.changeset(%UserFollow{}, %{
          user_id: user.id,
          remote_actor_id: remote_actor.id,
          state: "accepted",
          ap_id: "https://local.example/ap/users/alice#follow-1",
          accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert changeset.valid?
    end

    test "missing user_id is invalid" do
      remote_actor = create_remote_actor()

      changeset =
        UserFollow.changeset(%UserFollow{}, %{
          remote_actor_id: remote_actor.id,
          state: "pending",
          ap_id: "https://local.example/ap/users/alice#follow-1"
        })

      refute changeset.valid?
      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing remote_actor_id is invalid" do
      user = create_user()

      changeset =
        UserFollow.changeset(%UserFollow{}, %{
          user_id: user.id,
          state: "pending",
          ap_id: "https://local.example/ap/users/alice#follow-1"
        })

      refute changeset.valid?
      assert %{remote_actor_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing state is invalid" do
      user = create_user()
      remote_actor = create_remote_actor()

      changeset =
        UserFollow.changeset(%UserFollow{}, %{
          user_id: user.id,
          remote_actor_id: remote_actor.id,
          state: nil,
          ap_id: "https://local.example/ap/users/alice#follow-1"
        })

      refute changeset.valid?
      assert %{state: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing ap_id is invalid" do
      user = create_user()
      remote_actor = create_remote_actor()

      changeset =
        UserFollow.changeset(%UserFollow{}, %{
          user_id: user.id,
          remote_actor_id: remote_actor.id,
          state: "pending"
        })

      refute changeset.valid?
      assert %{ap_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid state value is rejected" do
      user = create_user()
      remote_actor = create_remote_actor()

      changeset =
        UserFollow.changeset(%UserFollow{}, %{
          user_id: user.id,
          remote_actor_id: remote_actor.id,
          state: "invalid_state",
          ap_id: "https://local.example/ap/users/alice#follow-1"
        })

      refute changeset.valid?
      assert %{state: ["is invalid"]} = errors_on(changeset)
    end

    test "unique constraint on [user_id, remote_actor_id]" do
      user = create_user()
      remote_actor = create_remote_actor()

      attrs = %{
        user_id: user.id,
        remote_actor_id: remote_actor.id,
        state: "pending",
        ap_id: "https://local.example/ap/users/alice#follow-1"
      }

      {:ok, _} =
        %UserFollow{}
        |> UserFollow.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %UserFollow{}
        |> UserFollow.changeset(%{attrs | ap_id: "https://local.example/ap/users/alice#follow-2"})
        |> Repo.insert()

      assert %{user_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "unique constraint on ap_id" do
      user1 = create_user()
      user2 = create_user()
      remote_actor = create_remote_actor()
      ap_id = "https://local.example/ap/users/alice#follow-unique"

      {:ok, _} =
        %UserFollow{}
        |> UserFollow.changeset(%{
          user_id: user1.id,
          remote_actor_id: remote_actor.id,
          state: "pending",
          ap_id: ap_id
        })
        |> Repo.insert()

      {:error, changeset} =
        %UserFollow{}
        |> UserFollow.changeset(%{
          user_id: user2.id,
          remote_actor_id: remote_actor.id,
          state: "pending",
          ap_id: ap_id
        })
        |> Repo.insert()

      assert %{ap_id: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
