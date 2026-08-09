defmodule Baudrate.Federation.InboxHandlerMoveTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{HTTPClient, InboxHandler, KeyStore, RemoteActor}
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
    {public_pem, _private_pem} = KeyStore.generate_keypair()

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      display_name: "Remote Actor #{uid}",
      # A real 2048-bit key: `Move` re-fetches the target actor, and
      # `ActorResolver` now refuses to cache a key it cannot decode.
      public_key_pem: public_pem,
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
    # Stubs the target actor document, claiming `aliases` in its alsoKnownAs.
    defp stub_target_actor(new_actor, aliases) do
      Req.Test.stub(HTTPClient, fn conn ->
        body =
          Jason.encode!(%{
            "id" => new_actor.ap_id,
            "type" => "Person",
            "preferredUsername" => new_actor.username,
            "inbox" => new_actor.inbox,
            "alsoKnownAs" => aliases,
            "publicKey" => %{
              "id" => "#{new_actor.ap_id}#main-key",
              "publicKeyPem" => new_actor.public_key_pem
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, body)
      end)
    end

    test "migrates follows to new actor", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})

      # Target claims the moving actor as an alias — authorizes the Move.
      stub_target_actor(new_actor, [actor.ap_id])

      activity = move_activity(actor, new_actor.ap_id)
      assert :ok = InboxHandler.handle(activity, actor, :shared)

      assert Federation.user_follows?(user.id, new_actor.id)
      refute Federation.user_follows?(user.id, actor.id)
    end

    test "deduplicates when user already follows new actor", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})
      create_accepted_follow(user, new_actor)

      stub_target_actor(new_actor, [actor.ap_id])

      activity = move_activity(actor, new_actor.ap_id)
      assert :ok = InboxHandler.handle(activity, actor, :shared)

      # Still follows new actor, old follow removed
      assert Federation.user_follows?(user.id, new_actor.id)
      refute Federation.user_follows?(user.id, actor.id)
    end

    test "rejects Move when target does not claim the mover as an alias",
         %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})

      # Target's alsoKnownAs does NOT include the moving actor — unauthorized.
      stub_target_actor(new_actor, ["https://someone-else.example/users/x"])

      activity = move_activity(actor, new_actor.ap_id)
      assert {:error, :move_not_authorized} = InboxHandler.handle(activity, actor, :shared)

      # Follows are left untouched — no forced redirect onto an unconsenting target.
      assert Federation.user_follows?(user.id, actor.id)
      refute Federation.user_follows?(user.id, new_actor.id)
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

    test "keeps the moved actor's feed history visible and interactable",
         %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})

      {:ok, authored} =
        Federation.create_feed_item(%{
          remote_actor_id: actor.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/pre-move-#{System.unique_integer([:positive])}",
          body: "posted before the move",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # An Announce keys feed membership on the booster, not the author.
      author = create_remote_actor(%{domain: "third.example"})

      {:ok, boosted} =
        Federation.create_feed_item(%{
          remote_actor_id: author.id,
          boosted_by_actor_id: actor.id,
          activity_type: "Announce",
          object_type: "Note",
          ap_id: "https://remote.example/announce-#{System.unique_integer([:positive])}",
          body: "boosted before the move",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert Federation.feed_item_accessible?(user, authored)
      assert Federation.feed_item_accessible?(user, boosted)

      stub_target_actor(new_actor, [actor.ap_id])
      assert :ok = InboxHandler.handle(move_activity(actor, new_actor.ap_id), actor, :shared)

      # The follow moved to the new actor, so items still pointing at the old
      # one would fail the accessibility join and vanish from the feed.
      authored = Repo.get!(Baudrate.Federation.FeedItem, authored.id)
      boosted = Repo.get!(Baudrate.Federation.FeedItem, boosted.id)

      assert authored.remote_actor_id == new_actor.id
      assert boosted.boosted_by_actor_id == new_actor.id
      # The original author of a boosted item is untouched.
      assert boosted.remote_actor_id == author.id

      assert Federation.feed_item_accessible?(user, authored)
      assert Federation.feed_item_accessible?(user, boosted)

      ids = Enum.map(Federation.list_feed_items(user).items, & &1.feed_item.id)
      assert authored.id in ids
      assert boosted.id in ids
    end

    test "an unauthorized Move leaves feed items where they are",
         %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})

      {:ok, item} =
        Federation.create_feed_item(%{
          remote_actor_id: actor.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/unauth-#{System.unique_integer([:positive])}",
          body: "stays put",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      stub_target_actor(new_actor, ["https://someone-else.example/users/x"])

      assert {:error, :move_not_authorized} =
               InboxHandler.handle(move_activity(actor, new_actor.ap_id), actor, :shared)

      assert Repo.get!(Baudrate.Federation.FeedItem, item.id).remote_actor_id == actor.id
      assert Federation.feed_item_accessible?(user, item)
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
