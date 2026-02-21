defmodule Baudrate.Federation.ActorResolverTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.{ActorResolver, KeyStore, RemoteActor}

  describe "resolve/1 caching" do
    test "returns cached actor within TTL" do
      {public_pem, _private_pem} = KeyStore.generate_keypair()

      {:ok, actor} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/cached",
          username: "cached",
          domain: "remote.example",
          public_key_pem: public_pem,
          inbox: "https://remote.example/users/cached/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      # Resolving should return the cached actor without making HTTP calls
      assert {:ok, resolved} = ActorResolver.resolve("https://remote.example/users/cached")
      assert resolved.id == actor.id
      assert resolved.ap_id == "https://remote.example/users/cached"
      assert resolved.username == "cached"
    end

    test "returns cached actor by key ID (strips fragment)" do
      {public_pem, _private_pem} = KeyStore.generate_keypair()

      {:ok, actor} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/keyed",
          username: "keyed",
          domain: "remote.example",
          public_key_pem: public_pem,
          inbox: "https://remote.example/users/keyed/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      assert {:ok, resolved} =
               ActorResolver.resolve_by_key_id("https://remote.example/users/keyed#main-key")

      assert resolved.id == actor.id
    end

    test "stale actor triggers refetch (which will fail without HTTP but demonstrates staleness)" do
      {public_pem, _private_pem} = KeyStore.generate_keypair()

      # Insert with a very old fetched_at to ensure staleness
      {:ok, _actor} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/stale",
          username: "stale",
          domain: "remote.example",
          public_key_pem: public_pem,
          inbox: "https://remote.example/users/stale/inbox",
          actor_type: "Person",
          fetched_at: ~U[2020-01-01 00:00:00Z]
        })
        |> Repo.insert()

      # Stale actor will attempt HTTP fetch which will fail
      assert {:error, _reason} = ActorResolver.resolve("https://remote.example/users/stale")
    end
  end
end
