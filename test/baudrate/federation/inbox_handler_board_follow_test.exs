defmodule Baudrate.Federation.InboxHandlerBoardFollowTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Federation
  alias Baudrate.Federation.{InboxHandler, KeyStore, RemoteActor}

  defp create_board(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      name: "Board #{uid}",
      slug: "board-#{uid}",
      min_role_to_view: "guest",
      ap_enabled: true,
      ap_accept_policy: "followers_only"
    }

    %Baudrate.Content.Board{}
    |> Baudrate.Content.Board.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
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

  describe "accept policy enforcement for Create(Article)" do
    test "followers_only board rejects content from unfollowed actor" do
      board = create_board(%{ap_accept_policy: "followers_only"})
      remote_actor = create_remote_actor()
      board_uri = Federation.actor_uri(:board, board.slug)

      activity = %{
        "id" => "https://remote.example/activities/create-#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/articles/#{System.unique_integer([:positive])}",
          "type" => "Article",
          "name" => "Rejected Article",
          "content" => "<p>Should be rejected</p>",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri],
          "to" => [board_uri]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      # Article should not be created in the board
      assert Content.get_article_by_ap_id(activity["object"]["id"]) == nil
    end

    test "followers_only board accepts content from followed actor" do
      board = create_board(%{ap_accept_policy: "followers_only"})
      remote_actor = create_remote_actor()
      board_uri = Federation.actor_uri(:board, board.slug)

      # Create and accept board follow
      {:ok, follow} = Federation.create_board_follow(board, remote_actor)
      {:ok, _} = Federation.accept_board_follow(follow.ap_id)

      ap_id = "https://remote.example/articles/#{System.unique_integer([:positive])}"

      activity = %{
        "id" => "https://remote.example/activities/create-#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Article",
          "name" => "Accepted Article",
          "content" => "<p>Should be accepted</p>",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri],
          "to" => [board_uri]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      article = Content.get_article_by_ap_id(ap_id)
      assert article != nil
      assert article.title == "Accepted Article"
    end

    test "open board accepts content from any actor" do
      board = create_board(%{ap_accept_policy: "open"})
      remote_actor = create_remote_actor()
      board_uri = Federation.actor_uri(:board, board.slug)

      ap_id = "https://remote.example/articles/#{System.unique_integer([:positive])}"

      activity = %{
        "id" => "https://remote.example/activities/create-#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Article",
          "name" => "Open Article",
          "content" => "<p>Anyone can post</p>",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri],
          "to" => [board_uri]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      article = Content.get_article_by_ap_id(ap_id)
      assert article != nil
    end

    test "pending board follow does not authorize content" do
      board = create_board(%{ap_accept_policy: "followers_only"})
      remote_actor = create_remote_actor()
      board_uri = Federation.actor_uri(:board, board.slug)

      # Create follow but don't accept it
      {:ok, _follow} = Federation.create_board_follow(board, remote_actor)

      activity = %{
        "id" => "https://remote.example/activities/create-#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/articles/#{System.unique_integer([:positive])}",
          "type" => "Article",
          "name" => "Pending Follow Article",
          "content" => "<p>Should be rejected</p>",
          "attributedTo" => remote_actor.ap_id,
          "audience" => [board_uri],
          "to" => [board_uri]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
      assert Content.get_article_by_ap_id(activity["object"]["id"]) == nil
    end
  end

  describe "Accept/Reject(Follow) fallback to board follow" do
    test "Accept(Follow) falls through to board follow when user follow not found" do
      board = create_board()
      remote_actor = create_remote_actor()

      {:ok, board_follow} = Federation.create_board_follow(board, remote_actor)
      assert board_follow.state == "pending"

      activity = %{
        "id" => "#{remote_actor.ap_id}#accept-follow-1",
        "type" => "Accept",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Follow",
          "id" => board_follow.ap_id,
          "actor" => Federation.actor_uri(:board, board.slug),
          "object" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      updated = Federation.get_board_follow_by_ap_id(board_follow.ap_id)
      assert updated.state == "accepted"
      assert updated.accepted_at != nil
    end

    test "Accept with string URI falls through to board follow" do
      board = create_board()
      remote_actor = create_remote_actor()

      {:ok, board_follow} = Federation.create_board_follow(board, remote_actor)

      activity = %{
        "id" => "#{remote_actor.ap_id}#accept-follow-2",
        "type" => "Accept",
        "actor" => remote_actor.ap_id,
        "object" => board_follow.ap_id
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      updated = Federation.get_board_follow_by_ap_id(board_follow.ap_id)
      assert updated.state == "accepted"
    end

    test "Reject(Follow) falls through to board follow" do
      board = create_board()
      remote_actor = create_remote_actor()

      {:ok, board_follow} = Federation.create_board_follow(board, remote_actor)

      activity = %{
        "id" => "#{remote_actor.ap_id}#reject-follow-1",
        "type" => "Reject",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Follow",
          "id" => board_follow.ap_id,
          "actor" => Federation.actor_uri(:board, board.slug),
          "object" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      updated = Federation.get_board_follow_by_ap_id(board_follow.ap_id)
      assert updated.state == "rejected"
      assert updated.rejected_at != nil
    end
  end

  describe "auto-routing to following boards" do
    test "Create(Article) from followed actor auto-routes when no audience match" do
      board = create_board()
      remote_actor = create_remote_actor()

      {:ok, follow} = Federation.create_board_follow(board, remote_actor)
      {:ok, _} = Federation.accept_board_follow(follow.ap_id)

      ap_id = "https://remote.example/articles/autoroute-#{System.unique_integer([:positive])}"

      # Article addressed to a non-local board (no audience match)
      activity = %{
        "id" => "https://remote.example/activities/create-#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Article",
          "name" => "Auto-Routed Article",
          "content" => "<p>Auto-routed content</p>",
          "attributedTo" => remote_actor.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      article = Content.get_article_by_ap_id(ap_id)
      assert article != nil
      assert article.title == "Auto-Routed Article"

      # Article should be linked to the board
      article = Repo.preload(article, :boards)
      assert Enum.any?(article.boards, &(&1.id == board.id))
    end

    test "Create(Note) from followed actor auto-routes when not a comment" do
      board = create_board()
      remote_actor = create_remote_actor()

      {:ok, follow} = Federation.create_board_follow(board, remote_actor)
      {:ok, _} = Federation.accept_board_follow(follow.ap_id)

      ap_id = "https://remote.example/notes/autoroute-#{System.unique_integer([:positive])}"

      # Note without inReplyTo (not a comment)
      activity = %{
        "id" => "https://remote.example/activities/create-#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Note",
          "content" => "<p>Auto-routed note content</p>",
          "attributedTo" => remote_actor.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      # Note should be auto-routed as an article
      article = Content.get_article_by_ap_id(ap_id)
      assert article != nil
      article = Repo.preload(article, :boards)
      assert Enum.any?(article.boards, &(&1.id == board.id))
    end

    test "no routing when board follow is pending" do
      board = create_board()
      remote_actor = create_remote_actor()

      # Create follow but DON'T accept it
      {:ok, _follow} = Federation.create_board_follow(board, remote_actor)

      ap_id = "https://remote.example/articles/no-route-#{System.unique_integer([:positive])}"

      activity = %{
        "id" => "https://remote.example/activities/create-#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "id" => ap_id,
          "type" => "Article",
          "name" => "Should Not Route",
          "content" => "<p>Not routed</p>",
          "attributedTo" => remote_actor.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      # Article should not exist in the board
      assert Content.get_article_by_ap_id(ap_id) == nil
    end
  end
end
