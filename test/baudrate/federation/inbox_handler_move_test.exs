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

    test "follows the new actor for real and unfollows the old one", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})

      # Target claims the moving actor as an alias — authorizes the Move.
      stub_target_actor(new_actor, [actor.ap_id])

      activity = move_activity(actor, new_actor.ap_id)
      assert :ok = InboxHandler.handle(activity, actor, :shared)

      refute Federation.user_follows?(user.id, actor.id)

      # A new Follow is sent, and the follow stays pending until the new actor
      # accepts it. Repointing the old row as "accepted" left the new server
      # unaware of the follower, so nothing was ever delivered (ADR 0025).
      assert %{state: "pending", ap_id: follow_ap_id} =
               Federation.get_user_follow(user.id, new_actor.id)

      jobs =
        Repo.all(Baudrate.Federation.DeliveryJob) |> Enum.map(&Jason.decode!(&1.activity_json))

      assert Enum.any?(
               jobs,
               &(&1["type"] == "Follow" and &1["id"] == follow_ap_id and
                   &1["object"] == new_actor.ap_id)
             )

      assert Enum.any?(jobs, &(&1["type"] == "Undo" and &1["object"]["object"] == actor.ap_id))

      assert [%{type: "actor_moved", actor_remote_actor_id: actor_id}] =
               Repo.all(
                 Ecto.Query.from(n in Baudrate.Notification.Notification,
                   where: n.user_id == ^user.id
                 )
               )

      assert actor_id == actor.id
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

    test "keeps the moved actor's feed history, visible once the new actor accepts",
         %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})

      {:ok, authored} =
        Federation.create_timeline_item(%{
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
        Federation.create_timeline_item(%{
          remote_actor_id: author.id,
          boosted_by_actor_id: actor.id,
          activity_type: "Announce",
          object_type: "Note",
          ap_id: "https://remote.example/announce-#{System.unique_integer([:positive])}",
          body: "boosted before the move",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert Federation.timeline_item_accessible?(user, authored)
      assert Federation.timeline_item_accessible?(user, boosted)

      stub_target_actor(new_actor, [actor.ap_id])
      assert :ok = InboxHandler.handle(move_activity(actor, new_actor.ap_id), actor, :shared)

      # The follow moved to the new actor, so items still pointing at the old
      # one would fail the accessibility join and vanish from the feed.
      authored = Repo.get!(Baudrate.Federation.TimelineItem, authored.id)
      boosted = Repo.get!(Baudrate.Federation.TimelineItem, boosted.id)

      assert authored.remote_actor_id == new_actor.id
      assert boosted.boosted_by_actor_id == new_actor.id
      # The original author of a boosted item is untouched.
      assert boosted.remote_actor_id == author.id

      # Pending until the new actor accepts the Follow sent on the user's behalf.
      refute Federation.timeline_item_accessible?(user, authored)
      follow = Federation.get_user_follow(user.id, new_actor.id)
      {:ok, _} = Federation.accept_user_follow(follow.ap_id)

      assert Federation.timeline_item_accessible?(user, authored)
      assert Federation.timeline_item_accessible?(user, boosted)

      ids = Enum.map(Federation.list_timeline_items(user).items, & &1.timeline_item.id)
      assert authored.id in ids
      assert boosted.id in ids
    end

    test "an unauthorized Move leaves timeline items where they are",
         %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})

      {:ok, item} =
        Federation.create_timeline_item(%{
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

      assert Repo.get!(Baudrate.Federation.TimelineItem, item.id).remote_actor_id == actor.id
      assert Federation.timeline_item_accessible?(user, item)
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

    test "refuses a Move of an object other than the signer", %{actor: actor} do
      activity = %{
        move_activity(actor, "https://new.example/users/x")
        | "object" => "https://x.example/u/y"
      }

      assert {:error, :actor_mismatch} = InboxHandler.handle(activity, actor, :shared)
    end

    test "ignores a Move to an account that has itself moved", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})
      {public_pem, _} = KeyStore.generate_keypair()

      Req.Test.stub(HTTPClient, fn conn ->
        Req.Test.json(conn, %{
          "id" => new_actor.ap_id,
          "type" => "Person",
          "preferredUsername" => new_actor.username,
          "inbox" => new_actor.inbox,
          "alsoKnownAs" => [actor.ap_id],
          "movedTo" => "https://third.example/users/elsewhere",
          "publicKey" => %{"id" => "#{new_actor.ap_id}#main-key", "publicKeyPem" => public_pem}
        })
      end)

      assert :ok = InboxHandler.handle(move_activity(actor, new_actor.ap_id), actor, :shared)
      assert Federation.user_follows?(user.id, actor.id)
    end

    test "processes one Move per actor every 30 days", %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      first = create_remote_actor(%{domain: "first.example"})
      stub_target_actor(first, [actor.ap_id])
      assert :ok = InboxHandler.handle(move_activity(actor, first.ap_id), actor, :shared)

      # The user follows the old actor again, and the actor tries to bounce elsewhere.
      create_accepted_follow(user, actor)
      second = create_remote_actor(%{domain: "second.example"})
      stub_target_actor(second, [actor.ap_id])

      assert :ok = InboxHandler.handle(move_activity(actor, second.ap_id), actor, :shared)
      assert Federation.user_follows?(user.id, actor.id)
      refute Federation.user_follows?(user.id, second.id)
      assert %{moved_to_ap_id: moved_to} = Repo.reload!(actor)
      assert moved_to == first.ap_id
    end

    test "a Move to a local account that lists the actor becomes a local follow",
         %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      destination = setup_user_with_role("user")

      Repo.update_all(
        Ecto.Query.from(u in Baudrate.Setup.User, where: u.id == ^destination.id),
        set: [also_known_as: [actor.ap_id]]
      )

      target_uri = Federation.actor_uri(:user, destination.username)
      assert :ok = InboxHandler.handle(move_activity(actor, target_uri), actor, :shared)

      assert Federation.local_follows?(user.id, destination.id)
      refute Federation.user_follows?(user.id, actor.id)
    end

    test "a Move to a local account that does not list the actor is refused",
         %{user: user, actor: actor} do
      create_accepted_follow(user, actor)
      destination = setup_user_with_role("user")
      target_uri = Federation.actor_uri(:user, destination.username)

      assert {:error, :move_not_authorized} =
               InboxHandler.handle(move_activity(actor, target_uri), actor, :shared)

      assert Federation.user_follows?(user.id, actor.id)
      refute Federation.local_follows?(user.id, destination.id)
    end

    test "board follows are not switched over; admins are told", %{actor: actor} do
      admin = setup_user_with_role("admin")

      board =
        %Baudrate.Content.Board{}
        |> Baudrate.Content.Board.changeset(%{
          name: "Relay",
          slug: "relay-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, board_follow} = Federation.create_board_follow(board, actor)
      new_actor = create_remote_actor(%{domain: "new.example"})
      stub_target_actor(new_actor, [actor.ap_id])

      assert :ok = InboxHandler.handle(move_activity(actor, new_actor.ap_id), actor, :shared)

      assert Repo.reload!(board_follow).remote_actor_id == actor.id

      assert [%{data: %{"boards" => ["Relay"], "label" => "@" <> _}}] =
               Repo.all(
                 Ecto.Query.from(n in Baudrate.Notification.Notification,
                   where: n.user_id == ^admin.id and n.type == "board_actor_moved"
                 )
               )
    end
  end
end
