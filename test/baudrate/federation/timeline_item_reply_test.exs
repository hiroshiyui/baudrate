defmodule Baudrate.Federation.TimelineItemReplyTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{TimelineItemReply, KeyStore, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "reply_user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    Repo.preload(user, :role)
  end

  defp create_remote_actor do
    uid = System.unique_integer([:positive])

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/actor-#{uid}",
        username: "actor_#{uid}",
        domain: "remote.example",
        public_key_pem: elem(KeyStore.generate_keypair(), 0),
        inbox: "https://remote.example/users/actor-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    actor
  end

  # Replying to a timeline item requires it to be reachable from the user's feed,
  # i.e. an accepted follow on the source actor.
  defp follow!(user, actor) do
    {:ok, follow} =
      %Baudrate.Federation.UserFollow{}
      |> Baudrate.Federation.UserFollow.changeset(%{
        user_id: user.id,
        remote_actor_id: actor.id,
        state: "accepted",
        ap_id: "https://local.example/follows/#{System.unique_integer([:positive])}",
        accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    follow
  end

  defp create_timeline_item(actor) do
    uid = System.unique_integer([:positive])

    {:ok, item} =
      Federation.create_timeline_item(%{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/#{uid}",
        body: "Hello from the fediverse",
        body_html: "<p>Hello from the fediverse</p>",
        source_url: "https://remote.example/notes/#{uid}",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    item
  end

  describe "TimelineItemReply changeset" do
    test "valid changeset with all required fields" do
      changeset =
        TimelineItemReply.changeset(%TimelineItemReply{}, %{
          body: "Great post!",
          timeline_item_id: 1,
          user_id: 1,
          ap_id: "https://example.com/replies/1"
        })

      assert changeset.valid?
    end

    test "requires body" do
      changeset =
        TimelineItemReply.changeset(%TimelineItemReply{}, %{
          timeline_item_id: 1,
          user_id: 1,
          ap_id: "https://example.com/replies/1"
        })

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires timeline_item_id" do
      changeset =
        TimelineItemReply.changeset(%TimelineItemReply{}, %{
          body: "Test",
          user_id: 1,
          ap_id: "https://example.com/replies/1"
        })

      assert %{timeline_item_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires user_id" do
      changeset =
        TimelineItemReply.changeset(%TimelineItemReply{}, %{
          body: "Test",
          timeline_item_id: 1,
          ap_id: "https://example.com/replies/1"
        })

      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires ap_id" do
      changeset =
        TimelineItemReply.changeset(%TimelineItemReply{}, %{
          body: "Test",
          timeline_item_id: 1,
          user_id: 1
        })

      assert %{ap_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates body max length" do
      long_body = String.duplicate("x", 10_001)

      changeset =
        TimelineItemReply.changeset(%TimelineItemReply{}, %{
          body: long_body,
          timeline_item_id: 1,
          user_id: 1,
          ap_id: "https://example.com/replies/1"
        })

      assert %{body: [msg]} = errors_on(changeset)
      assert msg =~ "at most 10000"
    end

    test "enforces unique ap_id constraint" do
      user = create_user()
      actor = create_remote_actor()
      follow!(user, actor)
      timeline_item = create_timeline_item(actor)

      ap_id = "https://example.com/replies/unique-#{System.unique_integer([:positive])}"

      {:ok, _} =
        %TimelineItemReply{}
        |> TimelineItemReply.changeset(%{
          body: "First reply",
          timeline_item_id: timeline_item.id,
          user_id: user.id,
          ap_id: ap_id
        })
        |> Repo.insert()

      {:error, changeset} =
        %TimelineItemReply{}
        |> TimelineItemReply.changeset(%{
          body: "Duplicate reply",
          timeline_item_id: timeline_item.id,
          user_id: user.id,
          ap_id: ap_id
        })
        |> Repo.insert()

      assert %{ap_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "create_timeline_item_reply/3" do
    test "creates a reply with generated AP ID and HTML body" do
      user = create_user()
      actor = create_remote_actor()
      follow!(user, actor)
      timeline_item = create_timeline_item(actor)

      {:ok, reply} = Federation.create_timeline_item_reply(timeline_item, user, "Nice post!")

      assert reply.body == "Nice post!"
      assert reply.body_html =~ "Nice post!"
      assert reply.timeline_item_id == timeline_item.id
      assert reply.user_id == user.id
      assert reply.ap_id =~ "#timeline-reply-"
      assert reply.ap_id =~ user.username
    end

    test "returns error for empty body" do
      user = create_user()
      actor = create_remote_actor()
      follow!(user, actor)
      timeline_item = create_timeline_item(actor)

      {:error, changeset} = Federation.create_timeline_item_reply(timeline_item, user, "")

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "refuses to reply to a timeline item the user does not follow" do
      user = create_user()
      actor = create_remote_actor()
      timeline_item = create_timeline_item(actor)

      assert {:error, :not_found} =
               Federation.create_timeline_item_reply(timeline_item, user, "Uninvited reply")

      assert Federation.list_timeline_item_replies(timeline_item.id) == []
    end

    test "refuses to reply to a soft-deleted timeline item" do
      user = create_user()
      actor = create_remote_actor()
      follow!(user, actor)
      timeline_item = create_timeline_item(actor)

      {:ok, deleted} =
        timeline_item
        |> Ecto.Changeset.change(%{
          deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()

      assert {:error, :not_found} =
               Federation.create_timeline_item_reply(deleted, user, "Reply to withdrawn post")
    end

    test "allows replying to a boost from a followed booster" do
      user = create_user()
      author = create_remote_actor()
      booster = create_remote_actor()
      follow!(user, booster)

      {:ok, boost_item} =
        Federation.create_timeline_item(%{
          remote_actor_id: author.id,
          boosted_by_actor_id: booster.id,
          activity_type: "Announce",
          object_type: "Note",
          ap_id: "https://remote.example/notes/boost-#{System.unique_integer([:positive])}",
          body: "Boosted content",
          body_html: "<p>Boosted content</p>",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert {:ok, reply} =
               Federation.create_timeline_item_reply(boost_item, user, "Seen via the booster")

      assert reply.timeline_item_id == boost_item.id
    end
  end

  describe "list_timeline_item_replies/1" do
    test "returns replies ordered by inserted_at ascending" do
      user = create_user()
      actor = create_remote_actor()
      follow!(user, actor)
      timeline_item = create_timeline_item(actor)

      {:ok, r1} = Federation.create_timeline_item_reply(timeline_item, user, "First reply")
      {:ok, r2} = Federation.create_timeline_item_reply(timeline_item, user, "Second reply")

      # Ensure distinct timestamps
      Repo.update_all(
        from(r in TimelineItemReply, where: r.id == ^r1.id),
        set: [inserted_at: ~U[2026-01-01 00:00:00Z]]
      )

      Repo.update_all(
        from(r in TimelineItemReply, where: r.id == ^r2.id),
        set: [inserted_at: ~U[2026-01-01 00:01:00Z]]
      )

      replies = Federation.list_timeline_item_replies(timeline_item.id)

      assert length(replies) == 2
      assert hd(replies).id == r1.id
      assert List.last(replies).id == r2.id
    end

    test "preloads user with role" do
      user = create_user()
      actor = create_remote_actor()
      follow!(user, actor)
      timeline_item = create_timeline_item(actor)

      {:ok, _} = Federation.create_timeline_item_reply(timeline_item, user, "Test reply")

      [reply] = Federation.list_timeline_item_replies(timeline_item.id)
      assert reply.user.id == user.id
      assert reply.user.role != nil
    end

    test "returns empty list for timeline item with no replies" do
      actor = create_remote_actor()
      timeline_item = create_timeline_item(actor)

      assert Federation.list_timeline_item_replies(timeline_item.id) == []
    end
  end

  describe "count_timeline_item_replies/1" do
    test "returns correct counts grouped by timeline_item_id" do
      user = create_user()
      actor = create_remote_actor()
      follow!(user, actor)
      fi1 = create_timeline_item(actor)
      fi2 = create_timeline_item(actor)

      {:ok, _} = Federation.create_timeline_item_reply(fi1, user, "Reply 1 to fi1")
      {:ok, _} = Federation.create_timeline_item_reply(fi1, user, "Reply 2 to fi1")
      {:ok, _} = Federation.create_timeline_item_reply(fi2, user, "Reply 1 to fi2")

      counts = Federation.count_timeline_item_replies([fi1.id, fi2.id])

      assert counts[fi1.id] == 2
      assert counts[fi2.id] == 1
    end

    test "returns empty map for empty input" do
      assert Federation.count_timeline_item_replies([]) == %{}
    end

    test "omits timeline items with zero replies" do
      actor = create_remote_actor()
      fi = create_timeline_item(actor)

      counts = Federation.count_timeline_item_replies([fi.id])
      refute Map.has_key?(counts, fi.id)
    end
  end
end
