defmodule Baudrate.Federation.AnnounceTest do
  use Baudrate.DataCase

  alias Baudrate.Federation.{Announce, KeyStore, RemoteActor}

  defp create_remote_actor do
    uid = System.unique_integer([:positive])
    {public_pem, _} = KeyStore.generate_keypair()

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/actor-#{uid}",
        username: "actor_#{uid}",
        domain: "remote.example",
        public_key_pem: public_pem,
        inbox: "https://remote.example/users/actor-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    actor
  end

  describe "changeset/2" do
    test "valid announce" do
      remote_actor = create_remote_actor()

      changeset =
        Announce.changeset(%Announce{}, %{
          ap_id: "https://remote.example/activities/announce-1",
          target_ap_id: "https://local.example/ap/articles/test",
          activity_id: "https://remote.example/activities/announce-1",
          remote_actor_id: remote_actor.id
        })

      assert changeset.valid?
    end

    test "requires all fields" do
      changeset = Announce.changeset(%Announce{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert %{ap_id: _, target_ap_id: _, activity_id: _, remote_actor_id: _} = errors
    end

    test "enforces unique ap_id" do
      remote_actor = create_remote_actor()

      attrs = %{
        ap_id: "https://remote.example/activities/announce-unique",
        target_ap_id: "https://local.example/ap/articles/test",
        activity_id: "https://remote.example/activities/announce-unique",
        remote_actor_id: remote_actor.id
      }

      {:ok, _} =
        %Announce{}
        |> Announce.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %Announce{}
        |> Announce.changeset(%{attrs | target_ap_id: "https://other.example/note/2"})
        |> Repo.insert()

      assert %{ap_id: _} = errors_on(changeset)
    end

    test "enforces unique (target_ap_id, remote_actor_id)" do
      remote_actor = create_remote_actor()

      attrs = %{
        ap_id: "https://remote.example/activities/announce-a",
        target_ap_id: "https://local.example/ap/articles/test",
        activity_id: "https://remote.example/activities/announce-a",
        remote_actor_id: remote_actor.id
      }

      {:ok, _} =
        %Announce{}
        |> Announce.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %Announce{}
        |> Announce.changeset(%{
          attrs
          | ap_id: "https://remote.example/activities/announce-b",
            activity_id: "https://remote.example/activities/announce-b"
        })
        |> Repo.insert()

      assert %{target_ap_id: _} = errors_on(changeset)
    end
  end
end
