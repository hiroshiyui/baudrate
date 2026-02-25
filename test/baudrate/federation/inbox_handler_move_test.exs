defmodule Baudrate.Federation.InboxHandlerMoveTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{HTTPClient, InboxHandler, RemoteActor}
  alias Baudrate.Repo

  setup do
    user = setup_user_with_role("user")
    actor = create_remote_actor()
    {:ok, user: user, actor: actor}
  end

  defp setup_user_with_role(role_name) do
    alias Baudrate.Setup
    alias Baudrate.Setup.User
    import Ecto.Query

    unless Repo.exists?(from(r in Baudrate.Setup.Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "feed_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      display_name: "Remote Actor #{uid}",
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

  defp create_accepted_follow(user, actor) do
    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, _follow} = Federation.accept_user_follow(follow.ap_id)
  end

  defp move_activity(old_actor, target_uri) do
    %{
      "type" => "Move",
      "id" => "https://remote.example/activities/move-#{System.unique_integer([:positive])}",
      "actor" => old_actor.ap_id,
      "target" => target_uri,
      "object" => old_actor.ap_id
    }
  end

  describe "Move activity" do
    test "migrates follows to new actor", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})

      # Stub HTTP for actor resolution
      Req.Test.stub(HTTPClient, fn conn ->
        body =
          Jason.encode!(%{
            "id" => new_actor.ap_id,
            "type" => "Person",
            "preferredUsername" => new_actor.username,
            "inbox" => new_actor.inbox,
            "publicKey" => %{
              "id" => "#{new_actor.ap_id}#main-key",
              "publicKeyPem" => new_actor.public_key_pem
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, body)
      end)

      activity = move_activity(actor, new_actor.ap_id)
      assert :ok = InboxHandler.handle(activity, actor, :shared)

      assert Federation.user_follows?(user.id, new_actor.id)
      refute Federation.user_follows?(user.id, actor.id)
    end

    test "deduplicates when user already follows new actor", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})
      create_accepted_follow(user, new_actor)

      Req.Test.stub(HTTPClient, fn conn ->
        body =
          Jason.encode!(%{
            "id" => new_actor.ap_id,
            "type" => "Person",
            "preferredUsername" => new_actor.username,
            "inbox" => new_actor.inbox,
            "publicKey" => %{
              "id" => "#{new_actor.ap_id}#main-key",
              "publicKeyPem" => new_actor.public_key_pem
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, body)
      end)

      activity = move_activity(actor, new_actor.ap_id)
      assert :ok = InboxHandler.handle(activity, actor, :shared)

      # Still follows new actor, old follow removed
      assert Federation.user_follows?(user.id, new_actor.id)
      refute Federation.user_follows?(user.id, actor.id)
    end

    test "logs warning when target is unresolvable", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)

      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      activity = move_activity(actor, "https://gone.example/users/nobody")
      assert :ok = InboxHandler.handle(activity, actor, :shared)

      # Follow unchanged
      assert Federation.user_follows?(user.id, actor.id)
    end

    test "rejects Move with actor mismatch", %{actor: actor} do
      other_actor = create_remote_actor()

      activity = %{
        "type" => "Move",
        "id" => "https://remote.example/activities/move-bad",
        "actor" => other_actor.ap_id,
        "target" => "https://new.example/users/someone",
        "object" => other_actor.ap_id
      }

      # The validate_actor_match check will reject because activity actor != signer
      assert {:error, :actor_mismatch} = InboxHandler.handle(activity, actor, :shared)
    end
  end
end
