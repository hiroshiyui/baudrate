defmodule Baudrate.Federation.InstanceStatsTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.{InstanceStats, KeyStore, RemoteActor}

  defp create_remote_actor(attrs) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
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

  describe "list_instances/0" do
    test "returns empty list when no remote actors" do
      assert InstanceStats.list_instances() == []
    end

    test "returns per-domain stats" do
      create_remote_actor(%{domain: "alpha.example"})
      create_remote_actor(%{domain: "alpha.example"})
      create_remote_actor(%{domain: "beta.example"})

      instances = InstanceStats.list_instances()
      assert length(instances) == 2

      alpha = Enum.find(instances, &(&1.domain == "alpha.example"))
      beta = Enum.find(instances, &(&1.domain == "beta.example"))

      assert alpha.actor_count == 2
      assert beta.actor_count == 1
    end

    test "includes follower counts" do
      actor = create_remote_actor(%{domain: "gamma.example"})

      # Create a follower record
      Baudrate.Federation.create_follower(
        "https://local.example/ap/users/alice",
        actor,
        "https://gamma.example/activities/follow-#{System.unique_integer([:positive])}"
      )

      instances = InstanceStats.list_instances()
      gamma = Enum.find(instances, &(&1.domain == "gamma.example"))
      assert gamma.follower_count == 1
    end
  end

  describe "list_actors_for_domain/1" do
    test "returns actors for specified domain" do
      create_remote_actor(%{domain: "target.example"})
      create_remote_actor(%{domain: "target.example"})
      create_remote_actor(%{domain: "other.example"})

      actors = InstanceStats.list_actors_for_domain("target.example")
      assert length(actors) == 2
      assert Enum.all?(actors, &(&1.domain == "target.example"))
    end

    test "returns empty for unknown domain" do
      assert InstanceStats.list_actors_for_domain("nonexistent.example") == []
    end
  end
end
