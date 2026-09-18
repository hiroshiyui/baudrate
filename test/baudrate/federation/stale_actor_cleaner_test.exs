defmodule Baudrate.Federation.StaleActorCleanerTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation.{
    Announce,
    TimelineItem,
    Follower,
    HTTPClient,
    RemoteActor,
    StaleActorCleaner,
    UserFollow
  }

  alias Baudrate.Content.{Article, ArticleLike, Comment}
  alias Baudrate.Messaging.Conversation
  alias Baudrate.Moderation.Report

  @valid_actor_attrs %{
    ap_id: "https://remote.example/users/alice",
    username: "alice",
    domain: "remote.example",
    public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
    inbox: "https://remote.example/users/alice/inbox",
    actor_type: "Person",
    fetched_at: ~U[2026-01-01 00:00:00Z]
  }

  defp create_remote_actor(overrides \\ %{}) do
    attrs = Map.merge(@valid_actor_attrs, overrides)

    %RemoteActor{}
    |> RemoteActor.changeset(attrs)
    |> Repo.insert!()
  end

  defp setup_user_with_role(role_name) do
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "test_#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp stale_fetched_at do
    # 31 days ago — beyond the default 30-day max age
    DateTime.utc_now() |> DateTime.add(-31 * 86_400, :second) |> DateTime.truncate(:second)
  end

  defp fresh_fetched_at do
    # 1 day ago — within the default 30-day max age
    DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.truncate(:second)
  end

  describe "init/1" do
    test "starts and schedules cleanup" do
      assert Process.alive?(Process.whereis(StaleActorCleaner))
    end
  end

  describe "run_cleanup/0" do
    test "deletes unreferenced stale actors" do
      actor = create_remote_actor(%{fetched_at: stale_fetched_at()})

      {_refreshed, deleted, _errors} = StaleActorCleaner.run_cleanup()

      assert deleted >= 1
      assert Repo.get(RemoteActor, actor.id) == nil
    end

    test "skips fresh actors" do
      actor = create_remote_actor(%{fetched_at: fresh_fetched_at()})

      {refreshed, deleted, errors} = StaleActorCleaner.run_cleanup()

      assert refreshed == 0
      assert deleted == 0
      assert errors == 0
      assert Repo.get(RemoteActor, actor.id) != nil
    end

    test "attempts refresh for stale actors with follower references" do
      actor = create_remote_actor(%{fetched_at: stale_fetched_at()})

      # Create a follower reference
      %Follower{}
      |> Ecto.Changeset.change(%{
        actor_uri: "https://local.example/ap/users/test",
        follower_uri: actor.ap_id,
        remote_actor_id: actor.id,
        activity_id: "https://remote.example/activities/follow-1"
      })
      |> Repo.insert!()

      # Stub HTTP to simulate refresh failure
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "")
      end)

      {_refreshed, deleted, _errors} = StaleActorCleaner.run_cleanup()

      # Actor should NOT be deleted (refresh attempted, errors expected in test env)
      assert deleted == 0
      assert Repo.get(RemoteActor, actor.id) != nil
    end

    test "attempts refresh for stale actors with article references" do
      actor = create_remote_actor(%{fetched_at: stale_fetched_at()})

      # Create an article reference
      %Article{}
      |> Ecto.Changeset.change(%{
        title: "Test Article",
        body: "Body",
        slug: "test-article-#{System.unique_integer([:positive])}",
        ap_id: "https://remote.example/articles/1",
        remote_actor_id: actor.id
      })
      |> Repo.insert!()

      # Stub HTTP to simulate refresh failure
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "")
      end)

      {_refreshed, deleted, _errors} = StaleActorCleaner.run_cleanup()

      assert deleted == 0
      assert Repo.get(RemoteActor, actor.id) != nil
    end

    test "handles multiple stale actors in batch" do
      actors =
        for i <- 1..3 do
          create_remote_actor(%{
            ap_id: "https://remote.example/users/user#{i}",
            username: "user#{i}",
            fetched_at: stale_fetched_at()
          })
        end

      {_refreshed, deleted, _errors} = StaleActorCleaner.run_cleanup()

      assert deleted >= 3

      for actor <- actors do
        assert Repo.get(RemoteActor, actor.id) == nil
      end
    end

    test "returns zero counts when no stale actors exist" do
      create_remote_actor(%{fetched_at: fresh_fetched_at()})

      assert {0, 0, 0} = StaleActorCleaner.run_cleanup()
    end
  end

  describe "has_references?/1" do
    test "returns false for unreferenced actor" do
      actor = create_remote_actor()
      refute StaleActorCleaner.has_references?(actor.id)
    end

    test "returns true when actor has followers" do
      actor = create_remote_actor()

      %Follower{}
      |> Ecto.Changeset.change(%{
        actor_uri: "https://local.example/ap/users/test",
        follower_uri: actor.ap_id,
        remote_actor_id: actor.id,
        activity_id: "https://remote.example/activities/follow-1"
      })
      |> Repo.insert!()

      assert StaleActorCleaner.has_references?(actor.id)
    end

    test "returns true when actor has articles" do
      actor = create_remote_actor()

      %Article{}
      |> Ecto.Changeset.change(%{
        title: "Test",
        body: "Body",
        slug: "test-ref-article-#{System.unique_integer([:positive])}",
        ap_id: "https://remote.example/articles/ref1",
        remote_actor_id: actor.id
      })
      |> Repo.insert!()

      assert StaleActorCleaner.has_references?(actor.id)
    end

    test "returns true when actor has comments" do
      actor = create_remote_actor()

      # Create an article first for the comment
      {:ok, article} =
        %Article{}
        |> Ecto.Changeset.change(%{
          title: "Host Article",
          body: "Body",
          slug: "host-article-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert()

      %Comment{}
      |> Ecto.Changeset.change(%{
        body: "A comment",
        ap_id: "https://remote.example/comments/1",
        article_id: article.id,
        remote_actor_id: actor.id
      })
      |> Repo.insert!()

      assert StaleActorCleaner.has_references?(actor.id)
    end

    test "returns true when actor has likes" do
      actor = create_remote_actor()

      {:ok, article} =
        %Article{}
        |> Ecto.Changeset.change(%{
          title: "Liked Article",
          body: "Body",
          slug: "liked-article-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert()

      %ArticleLike{}
      |> Ecto.Changeset.change(%{
        ap_id: "https://remote.example/likes/1",
        article_id: article.id,
        remote_actor_id: actor.id
      })
      |> Repo.insert!()

      assert StaleActorCleaner.has_references?(actor.id)
    end

    test "returns true when actor has announces" do
      actor = create_remote_actor()

      %Announce{}
      |> Ecto.Changeset.change(%{
        ap_id: "https://remote.example/announces/1",
        target_ap_id: "https://local.example/ap/articles/test",
        activity_id: "https://remote.example/activities/announce-1",
        remote_actor_id: actor.id
      })
      |> Repo.insert!()

      assert StaleActorCleaner.has_references?(actor.id)
    end

    test "returns true when actor has reports" do
      actor = create_remote_actor()

      %Report{}
      |> Ecto.Changeset.change(%{
        reason: "spam",
        remote_actor_id: actor.id
      })
      |> Repo.insert!()

      assert StaleActorCleaner.has_references?(actor.id)
    end
  end

  # The reference check used to be six hand-written queries against nineteen
  # foreign keys. An actor that only the other thirteen pointed at looked
  # unreferenced, and deleting it cascaded: a member lost a follow and every
  # timeline item from an account that had simply gone quiet for a month.
  describe "references the hand-written list used to miss" do
    setup do
      # Referenced actors are refreshed rather than deleted; the refresh fails
      # here, which is what the existing tests rely on too.
      Req.Test.stub(HTTPClient, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      :ok
    end

    test "every foreign key pointing at remote_actors is covered" do
      columns = StaleActorCleaner.referencing_columns()

      # Deleting a row in any of these takes data with it (ON DELETE CASCADE).
      for column <- [
            {"article_boosts", "remote_actor_id"},
            {"board_follows", "remote_actor_id"},
            {"comment_boosts", "remote_actor_id"},
            {"comment_likes", "remote_actor_id"},
            {"timeline_items", "remote_actor_id"},
            {"poll_votes", "remote_actor_id"},
            {"user_follows", "remote_actor_id"}
          ] do
        assert column in columns, "#{inspect(column)} is not covered by the reference check"
      end

      # These only lose the link (ON DELETE SET NULL), which is just as silent.
      for column <- [
            {"conversations", "remote_actor_a_id"},
            {"conversations", "remote_actor_b_id"},
            {"direct_messages", "sender_remote_actor_id"},
            {"timeline_items", "boosted_by_actor_id"},
            {"notifications", "actor_remote_actor_id"},
            {"reports", "reporter_remote_actor_id"}
          ] do
        assert column in columns, "#{inspect(column)} is not covered by the reference check"
      end
    end

    test "a member's follow of a quiet actor survives the sweep" do
      user = setup_user_with_role("user")
      actor = create_remote_actor(%{fetched_at: stale_fetched_at()})

      follow =
        %UserFollow{}
        |> UserFollow.changeset(%{
          user_id: user.id,
          remote_actor_id: actor.id,
          state: "accepted",
          ap_id: "https://local.example/ap/follows/#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      StaleActorCleaner.run_cleanup()

      assert Repo.get(RemoteActor, actor.id)
      assert Repo.get(UserFollow, follow.id)
    end

    test "timeline items from a quiet actor survive the sweep" do
      actor = create_remote_actor(%{fetched_at: stale_fetched_at()})

      item =
        %TimelineItem{}
        |> TimelineItem.changeset(%{
          remote_actor_id: actor.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/#{System.unique_integer([:positive])}",
          body: "Still here",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert!()

      StaleActorCleaner.run_cleanup()

      assert Repo.get(RemoteActor, actor.id)
      assert Repo.get(TimelineItem, item.id)
    end

    test "a conversation with a quiet actor survives the sweep" do
      user = setup_user_with_role("user")
      actor = create_remote_actor(%{fetched_at: stale_fetched_at()})

      conversation =
        %Conversation{}
        |> Conversation.remote_changeset(%{
          user_a_id: user.id,
          remote_actor_b_id: actor.id
        })
        |> Repo.insert!()

      StaleActorCleaner.run_cleanup()

      assert Repo.get(RemoteActor, actor.id)
      assert Repo.get(Conversation, conversation.id).remote_actor_b_id == actor.id
    end

    test "has_references?/1 sees a follow, a timeline item and a conversation" do
      user = setup_user_with_role("user")

      followed = create_remote_actor(%{ap_id: "https://remote.example/users/f", username: "f"})
      poster = create_remote_actor(%{ap_id: "https://remote.example/users/p", username: "p"})

      correspondent =
        create_remote_actor(%{ap_id: "https://remote.example/users/c", username: "c"})

      %UserFollow{}
      |> UserFollow.changeset(%{
        user_id: user.id,
        remote_actor_id: followed.id,
        state: "accepted",
        ap_id: "https://local.example/ap/follows/#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

      %TimelineItem{}
      |> TimelineItem.changeset(%{
        remote_actor_id: poster.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/#{System.unique_integer([:positive])}",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

      %Conversation{}
      |> Conversation.remote_changeset(%{user_a_id: user.id, remote_actor_b_id: correspondent.id})
      |> Repo.insert!()

      assert StaleActorCleaner.has_references?(followed.id)
      assert StaleActorCleaner.has_references?(poster.id)
      assert StaleActorCleaner.has_references?(correspondent.id)
    end
  end
end
