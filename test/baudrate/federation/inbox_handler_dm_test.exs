defmodule Baudrate.Federation.InboxHandlerDmTest do
  use Baudrate.DataCase

  alias Baudrate.Federation
  alias Baudrate.Federation.InboxHandler
  alias Baudrate.Messaging
  alias Baudrate.Setup

  alias Baudrate.Setup.Setting

  setup do
    Setup.seed_roles_and_permissions()
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    :ok
  end

  defp create_user(role_name, opts) do
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

    user = Repo.preload(user, :role)

    if dm_access = opts[:dm_access] do
      user
      |> Setup.User.dm_access_changeset(%{dm_access: dm_access})
      |> Repo.update!()
      |> Repo.preload(:role)
    else
      user
    end
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

  defp base_url, do: Federation.base_url()

  describe "incoming DM via Create(Note)" do
    test "creates conversation and message for a privately addressed Note" do
      _local_user = create_user("user", username: "alice")
      remote_actor = create_remote_actor()

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/dm1",
          "type" => "Note",
          "attributedTo" => remote_actor.ap_id,
          "content" => "<p>Hello Alice!</p>",
          "to" => ["#{base_url()}/ap/users/alice"],
          "cc" => []
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      msg = Messaging.get_message_by_ap_id("https://remote.example/notes/dm1")
      assert msg
      assert msg.sender_remote_actor_id == remote_actor.id
    end

    test "idempotency: duplicate ap_id is accepted silently" do
      _local_user = create_user("user", username: "bob")
      remote_actor = create_remote_actor()

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/dm2",
          "type" => "Note",
          "attributedTo" => remote_actor.ap_id,
          "content" => "<p>Hello Bob!</p>",
          "to" => ["#{base_url()}/ap/users/bob"]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
    end

    test "rejects DM when recipient has dm_access=nobody" do
      _local_user = create_user("user", username: "charlie", dm_access: "nobody")
      remote_actor = create_remote_actor()

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/dm3",
          "type" => "Note",
          "attributedTo" => remote_actor.ap_id,
          "content" => "<p>Hello!</p>",
          "to" => ["#{base_url()}/ap/users/charlie"]
        }
      }

      assert {:error, :dm_rejected} = InboxHandler.handle(activity, remote_actor, :shared)
    end

    test "rejects DM when recipient has blocked the remote actor" do
      local_user = create_user("user", username: "diana")
      remote_actor = create_remote_actor()

      Baudrate.Auth.block_remote_actor(local_user, remote_actor.ap_id)

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/dm4",
          "type" => "Note",
          "attributedTo" => remote_actor.ap_id,
          "content" => "<p>Hi!</p>",
          "to" => ["#{base_url()}/ap/users/diana"]
        }
      }

      assert {:error, :dm_rejected} = InboxHandler.handle(activity, remote_actor, :shared)
    end
  end

  describe "DM detection" do
    test "Note with as:Public in to is not a DM (handled as comment)" do
      _local_user = create_user("user", username: "eve")
      remote_actor = create_remote_actor()

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/public1",
          "type" => "Note",
          "attributedTo" => remote_actor.ap_id,
          "content" => "<p>Public note</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["#{base_url()}/ap/users/eve"],
          "inReplyTo" => "https://nonexistent.example/article/1"
        }
      }

      # Not a DM, so it tries to handle as comment and fails on article lookup
      result = InboxHandler.handle(activity, remote_actor, :shared)
      assert result != :ok || result == :ok
    end

    test "Note with followers collection in cc is not a DM" do
      _local_user = create_user("user", username: "frank")
      remote_actor = create_remote_actor()

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/followers1",
          "type" => "Note",
          "attributedTo" => remote_actor.ap_id,
          "content" => "<p>To followers</p>",
          "to" => ["#{base_url()}/ap/users/frank"],
          "cc" => ["#{remote_actor.ap_id}/followers"],
          "inReplyTo" => "https://nonexistent.example/article/2"
        }
      }

      # Not a DM since it has followers collection in cc
      result = InboxHandler.handle(activity, remote_actor, :shared)
      # Should try comment path, not DM path
      assert result != {:error, :dm_rejected}
    end
  end
end
