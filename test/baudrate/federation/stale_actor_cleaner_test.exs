defmodule Baudrate.Federation.StaleActorCleanerTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation.{Announce, Follower, RemoteActor, StaleActorCleaner}
  alias Baudrate.Content.{Article, ArticleLike, Comment}

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
  end
end
