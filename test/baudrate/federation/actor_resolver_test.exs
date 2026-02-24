defmodule Baudrate.Federation.ActorResolverTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.{ActorResolver, HTTPClient, KeyStore, RemoteActor}

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

    test "stale actor triggers refetch" do
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

      # Stale actor will attempt HTTP fetch — stub returns 500 to simulate failure
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "")
      end)

      assert {:error, _reason} = ActorResolver.resolve("https://remote.example/users/stale")
    end
  end

  describe "resolve/1 remote fetch" do
    test "fetches and caches new actor" do
      {public_pem, _private_pem} = KeyStore.generate_keypair()

      actor_json =
        Jason.encode!(%{
          "id" => "https://remote.example/users/new-actor",
          "type" => "Person",
          "preferredUsername" => "new-actor",
          "inbox" => "https://remote.example/users/new-actor/inbox",
          "publicKey" => %{
            "id" => "https://remote.example/users/new-actor#main-key",
            "publicKeyPem" => public_pem
          }
        })

      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, actor_json)
      end)

      assert {:ok, actor} = ActorResolver.resolve("https://remote.example/users/new-actor")
      assert actor.ap_id == "https://remote.example/users/new-actor"
      assert actor.username == "new-actor"
      assert actor.domain == "remote.example"
      assert actor.public_key_pem == public_pem

      # Verify it's cached in DB
      assert Repo.get_by(RemoteActor, ap_id: "https://remote.example/users/new-actor")
    end

    test "returns error on invalid JSON response" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"invalid": "no id field"}))
      end)

      assert {:error, _} = ActorResolver.resolve("https://remote.example/users/bad-json")
    end

    test "returns error on HTTP failure" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, _} = ActorResolver.resolve("https://remote.example/users/server-error")
    end
  end

  describe "refresh/1" do
    test "updates cached actor with fresh data" do
      {public_pem, _private_pem} = KeyStore.generate_keypair()
      {new_public_pem, _} = KeyStore.generate_keypair()

      {:ok, _original} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/refresh-me",
          username: "refresh-me",
          domain: "remote.example",
          display_name: "Old Name",
          public_key_pem: public_pem,
          inbox: "https://remote.example/users/refresh-me/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      updated_json =
        Jason.encode!(%{
          "id" => "https://remote.example/users/refresh-me",
          "type" => "Person",
          "preferredUsername" => "refresh-me",
          "name" => "New Name",
          "inbox" => "https://remote.example/users/refresh-me/inbox",
          "publicKey" => %{
            "id" => "https://remote.example/users/refresh-me#main-key",
            "publicKeyPem" => new_public_pem
          }
        })

      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, updated_json)
      end)

      assert {:ok, refreshed} = ActorResolver.refresh("https://remote.example/users/refresh-me")
      assert refreshed.display_name == "New Name"
      assert refreshed.public_key_pem == new_public_pem
    end
  end

  describe "resolve/1 validation" do
    test "rejects non-HTTPS URL" do
      assert {:error, :invalid_actor_url} =
               ActorResolver.resolve("http://remote.example/users/alice")
    end
  end
end
