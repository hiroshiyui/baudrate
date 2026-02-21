defmodule Baudrate.Federation.FollowerTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.{Follower, RemoteActor}

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
      remote_actor = create_remote_actor()

      changeset =
        Follower.changeset(%Follower{}, %{
          actor_uri: "https://local.example/ap/users/bob",
          follower_uri: remote_actor.ap_id,
          remote_actor_id: remote_actor.id,
          activity_id: "https://remote.example/activities/follow-1"
        })

      assert changeset.valid?
    end

    test "valid changeset with optional accepted_at" do
      remote_actor = create_remote_actor()

      changeset =
        Follower.changeset(%Follower{}, %{
          actor_uri: "https://local.example/ap/users/bob",
          follower_uri: remote_actor.ap_id,
          remote_actor_id: remote_actor.id,
          activity_id: "https://remote.example/activities/follow-1",
          accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert changeset.valid?
    end

    test "missing actor_uri is invalid" do
      remote_actor = create_remote_actor()

      changeset =
        Follower.changeset(%Follower{}, %{
          follower_uri: remote_actor.ap_id,
          remote_actor_id: remote_actor.id,
          activity_id: "https://remote.example/activities/follow-1"
        })

      refute changeset.valid?
      assert %{actor_uri: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing follower_uri is invalid" do
      remote_actor = create_remote_actor()

      changeset =
        Follower.changeset(%Follower{}, %{
          actor_uri: "https://local.example/ap/users/bob",
          remote_actor_id: remote_actor.id,
          activity_id: "https://remote.example/activities/follow-1"
        })

      refute changeset.valid?
      assert %{follower_uri: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing remote_actor_id is invalid" do
      changeset =
        Follower.changeset(%Follower{}, %{
          actor_uri: "https://local.example/ap/users/bob",
          follower_uri: "https://remote.example/users/alice",
          activity_id: "https://remote.example/activities/follow-1"
        })

      refute changeset.valid?
      assert %{remote_actor_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing activity_id is invalid" do
      remote_actor = create_remote_actor()

      changeset =
        Follower.changeset(%Follower{}, %{
          actor_uri: "https://local.example/ap/users/bob",
          follower_uri: remote_actor.ap_id,
          remote_actor_id: remote_actor.id
        })

      refute changeset.valid?
      assert %{activity_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "unique constraint on [actor_uri, follower_uri]" do
      remote_actor = create_remote_actor()

      attrs = %{
        actor_uri: "https://local.example/ap/users/bob",
        follower_uri: remote_actor.ap_id,
        remote_actor_id: remote_actor.id,
        activity_id: "https://remote.example/activities/follow-1"
      }

      {:ok, _} =
        %Follower{}
        |> Follower.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %Follower{}
        |> Follower.changeset(
          Map.put(attrs, :activity_id, "https://remote.example/activities/follow-2")
        )
        |> Repo.insert()

      assert %{actor_uri: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
