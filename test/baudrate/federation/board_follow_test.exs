defmodule Baudrate.Federation.BoardFollowTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{BoardFollow, RemoteActor}

  defp create_board(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      name: "Board #{uid}",
      slug: "board-#{uid}",
      min_role_to_view: "guest",
      ap_enabled: true,
      ap_accept_policy: "followers_only"
    }

    {:ok, board} =
      %Baudrate.Content.Board{}
      |> Baudrate.Content.Board.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    board
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
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

  describe "create_board_follow/2" do
    test "creates a pending follow record" do
      board = create_board()
      remote_actor = create_remote_actor()

      assert {:ok, %BoardFollow{} = follow} = Federation.create_board_follow(board, remote_actor)
      assert follow.board_id == board.id
      assert follow.remote_actor_id == remote_actor.id
      assert follow.state == "pending"
      assert follow.ap_id =~ "#follow-"
      assert is_nil(follow.accepted_at)
      assert is_nil(follow.rejected_at)
    end

    test "returns error for duplicate follow" do
      board = create_board()
      remote_actor = create_remote_actor()

      assert {:ok, _} = Federation.create_board_follow(board, remote_actor)
      assert {:error, changeset} = Federation.create_board_follow(board, remote_actor)
      assert %{board_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "accept_board_follow/1" do
    test "transitions follow from pending to accepted" do
      board = create_board()
      remote_actor = create_remote_actor()
      {:ok, follow} = Federation.create_board_follow(board, remote_actor)

      assert {:ok, updated} = Federation.accept_board_follow(follow.ap_id)
      assert updated.state == "accepted"
      assert updated.accepted_at != nil
    end

    test "returns not_found for unknown ap_id" do
      assert {:error, :not_found} = Federation.accept_board_follow("https://unknown/follow")
    end
  end

  describe "reject_board_follow/1" do
    test "transitions follow from pending to rejected" do
      board = create_board()
      remote_actor = create_remote_actor()
      {:ok, follow} = Federation.create_board_follow(board, remote_actor)

      assert {:ok, updated} = Federation.reject_board_follow(follow.ap_id)
      assert updated.state == "rejected"
      assert updated.rejected_at != nil
    end

    test "returns not_found for unknown ap_id" do
      assert {:error, :not_found} = Federation.reject_board_follow("https://unknown/follow")
    end
  end

  describe "delete_board_follow/2" do
    test "deletes an existing follow" do
      board = create_board()
      remote_actor = create_remote_actor()
      {:ok, _follow} = Federation.create_board_follow(board, remote_actor)

      assert {:ok, _deleted} = Federation.delete_board_follow(board, remote_actor)
      assert is_nil(Federation.get_board_follow(board.id, remote_actor.id))
    end

    test "returns not_found when follow does not exist" do
      board = create_board()
      remote_actor = create_remote_actor()

      assert {:error, :not_found} = Federation.delete_board_follow(board, remote_actor)
    end
  end

  describe "get_board_follow/2" do
    test "returns the follow record" do
      board = create_board()
      remote_actor = create_remote_actor()
      {:ok, follow} = Federation.create_board_follow(board, remote_actor)

      found = Federation.get_board_follow(board.id, remote_actor.id)
      assert found.id == follow.id
    end

    test "returns nil when not found" do
      assert is_nil(Federation.get_board_follow(0, 0))
    end
  end

  describe "board_follows_actor?/2" do
    test "returns true for accepted follow" do
      board = create_board()
      remote_actor = create_remote_actor()
      {:ok, follow} = Federation.create_board_follow(board, remote_actor)
      Federation.accept_board_follow(follow.ap_id)

      assert Federation.board_follows_actor?(board.id, remote_actor.id)
    end

    test "returns false for pending follow" do
      board = create_board()
      remote_actor = create_remote_actor()
      {:ok, _follow} = Federation.create_board_follow(board, remote_actor)

      refute Federation.board_follows_actor?(board.id, remote_actor.id)
    end

    test "returns false when no follow exists" do
      board = create_board()
      remote_actor = create_remote_actor()

      refute Federation.board_follows_actor?(board.id, remote_actor.id)
    end
  end

  describe "boards_following_actor/1" do
    test "returns boards with accepted follows for the actor" do
      board1 = create_board()
      board2 = create_board()
      remote_actor = create_remote_actor()

      {:ok, f1} = Federation.create_board_follow(board1, remote_actor)
      {:ok, f2} = Federation.create_board_follow(board2, remote_actor)
      Federation.accept_board_follow(f1.ap_id)
      Federation.accept_board_follow(f2.ap_id)

      boards = Federation.boards_following_actor(remote_actor.id)
      board_ids = Enum.map(boards, & &1.id) |> Enum.sort()
      assert board_ids == Enum.sort([board1.id, board2.id])
    end

    test "excludes boards with pending follows" do
      board = create_board()
      remote_actor = create_remote_actor()
      {:ok, _follow} = Federation.create_board_follow(board, remote_actor)

      assert Federation.boards_following_actor(remote_actor.id) == []
    end

    test "excludes non-federated boards" do
      board = create_board(%{ap_enabled: false})
      remote_actor = create_remote_actor()
      {:ok, follow} = Federation.create_board_follow(board, remote_actor)
      Federation.accept_board_follow(follow.ap_id)

      assert Federation.boards_following_actor(remote_actor.id) == []
    end
  end

  describe "list_board_follows/2" do
    test "returns follows with remote actor preloaded" do
      board = create_board()
      remote_actor = create_remote_actor()
      {:ok, _follow} = Federation.create_board_follow(board, remote_actor)

      follows = Federation.list_board_follows(board.id)
      assert length(follows) == 1
      assert hd(follows).remote_actor.id == remote_actor.id
    end

    test "filters by state" do
      board = create_board()
      actor1 = create_remote_actor()
      actor2 = create_remote_actor()

      {:ok, f1} = Federation.create_board_follow(board, actor1)
      {:ok, _f2} = Federation.create_board_follow(board, actor2)
      Federation.accept_board_follow(f1.ap_id)

      accepted = Federation.list_board_follows(board.id, state: "accepted")
      assert length(accepted) == 1
      assert hd(accepted).remote_actor_id == actor1.id

      pending = Federation.list_board_follows(board.id, state: "pending")
      assert length(pending) == 1
      assert hd(pending).remote_actor_id == actor2.id
    end
  end

  describe "count_board_follows/1" do
    test "counts only accepted follows" do
      board = create_board()
      actor1 = create_remote_actor()
      actor2 = create_remote_actor()

      {:ok, f1} = Federation.create_board_follow(board, actor1)
      {:ok, _f2} = Federation.create_board_follow(board, actor2)
      Federation.accept_board_follow(f1.ap_id)

      assert Federation.count_board_follows(board.id) == 1
    end
  end
end
