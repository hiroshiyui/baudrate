defmodule Baudrate.Content.BoardModeratorTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Repo
  alias Baudrate.Setup

  import Ecto.Query

  setup do
    unless Repo.exists?(from(r in Setup.Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    user_role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    make_user = fn ->
      {:ok, user} =
        %Setup.User{}
        |> Setup.User.registration_changeset(%{
          "username" => "mod_test_#{System.unique_integer([:positive])}",
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "role_id" => user_role.id
        })
        |> Repo.insert()

      user
    end

    user1 = make_user.()
    user2 = make_user.()

    {:ok, board} = Content.create_board(%{name: "Mod Board", slug: "mod-board-#{System.unique_integer([:positive])}"})

    {:ok, board: board, user1: user1, user2: user2}
  end

  describe "add_board_moderator/2" do
    test "adds a user as board moderator", %{board: board, user1: user1} do
      assert {:ok, bm} = Content.add_board_moderator(board.id, user1.id)
      assert bm.board_id == board.id
      assert bm.user_id == user1.id
    end

    test "rejects duplicate assignment", %{board: board, user1: user1} do
      {:ok, _} = Content.add_board_moderator(board.id, user1.id)
      assert {:error, changeset} = Content.add_board_moderator(board.id, user1.id)
      assert changeset.errors[:board_id] || changeset.errors[:user_id]
    end
  end

  describe "remove_board_moderator/2" do
    test "removes a board moderator", %{board: board, user1: user1} do
      {:ok, _} = Content.add_board_moderator(board.id, user1.id)
      assert {1, _} = Content.remove_board_moderator(board.id, user1.id)

      mods = Content.list_board_moderators(board)
      assert mods == []
    end

    test "noop for non-existent assignment", %{board: board, user1: user1} do
      assert {0, _} = Content.remove_board_moderator(board.id, user1.id)
    end
  end

  describe "list_board_moderators/1" do
    test "lists moderators with user preloaded", %{board: board, user1: user1, user2: user2} do
      {:ok, _} = Content.add_board_moderator(board.id, user1.id)
      {:ok, _} = Content.add_board_moderator(board.id, user2.id)

      mods = Content.list_board_moderators(board)
      assert length(mods) == 2

      usernames = Enum.map(mods, & &1.user.username)
      assert user1.username in usernames
      assert user2.username in usernames
    end

    test "returns empty list when no moderators", %{board: board} do
      assert Content.list_board_moderators(board) == []
    end
  end
end
