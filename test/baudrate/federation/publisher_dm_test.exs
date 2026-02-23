defmodule Baudrate.Federation.PublisherDmTest do
  use Baudrate.DataCase

  alias Baudrate.Federation
  alias Baudrate.Federation.Publisher
  alias Baudrate.Messaging
  alias Baudrate.Setup

  alias Baudrate.Setup.Setting

  setup do
    Setup.seed_roles_and_permissions()
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    :ok
  end

  defp create_user(role_name, opts \\ []) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => opts[:username] || "user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_remote_actor(attrs \\ %{}) do
    defaults = %{
      ap_id: "https://remote.example/users/#{System.unique_integer([:positive])}",
      username: "remote_#{System.unique_integer([:positive])}",
      domain: "remote.example",
      display_name: "Remote User",
      inbox: "https://remote.example/inbox",
      public_key_pem: "fake-key",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    merged = Map.merge(defaults, attrs)

    %Federation.RemoteActor{}
    |> Federation.RemoteActor.changeset(merged)
    |> Repo.insert!()
  end

  describe "build_create_dm/3" do
    test "builds a Create(Note) with correct addressing" do
      sender = create_user("user", username: "sender")
      remote_actor = create_remote_actor()

      {:ok, conv} = Messaging.find_or_create_remote_conversation(sender, remote_actor)
      {:ok, msg} = Messaging.create_message(conv, sender, %{body: "Hello remote!"})

      {activity, actor_uri} = Publisher.build_create_dm(msg, conv, sender)

      assert activity["type"] == "Create"
      assert actor_uri =~ "/ap/users/sender"
      assert activity["actor"] == actor_uri

      object = activity["object"]
      assert object["type"] == "Note"
      assert [recipient_uri] = object["to"]
      assert recipient_uri == remote_actor.ap_id

      # No public addressing
      refute "https://www.w3.org/ns/activitystreams#Public" in (object["to"] ++ (object["cc"] || []))

      # Has Mention tag
      [mention] = object["tag"]
      assert mention["type"] == "Mention"
      assert mention["href"] == remote_actor.ap_id

      # Has context
      assert object["context"] == conv.ap_context
      assert object["conversation"] == conv.ap_context
    end
  end

  describe "build_delete_dm/3" do
    test "builds a Delete(Tombstone) with correct addressing" do
      sender = create_user("user", username: "deleter")
      remote_actor = create_remote_actor()

      {:ok, conv} = Messaging.find_or_create_remote_conversation(sender, remote_actor)
      {:ok, msg} = Messaging.create_message(conv, sender, %{body: "To be deleted"})

      {activity, actor_uri} = Publisher.build_delete_dm(msg, sender, conv)

      assert activity["type"] == "Delete"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Tombstone"
      assert [recipient_uri] = activity["to"]
      assert recipient_uri == remote_actor.ap_id
    end
  end

  describe "publish_dm_created/3" do
    test "skips delivery for local-only conversations" do
      user_a = create_user("user")
      user_b = create_user("user")

      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)
      {:ok, msg} = Messaging.create_message(conv, user_a, %{body: "Local only"})

      assert {:ok, 0} = Publisher.publish_dm_created(msg, conv, user_a)
    end
  end
end
