defmodule Baudrate.Content.BoardManagementTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{BoardArticle, Article}
  alias Baudrate.Repo

  setup do
    import Ecto.Query
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == "user"))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "board_test_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user: user}
  end

  describe "get_board!/1" do
    test "returns a board by ID" do
      {:ok, board} = Content.create_board(%{name: "Test", slug: "test-get-#{System.unique_integer([:positive])}"})
      fetched = Content.get_board!(board.id)
      assert fetched.id == board.id
    end

    test "raises for non-existent ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Content.get_board!(999_999)
      end
    end
  end

  describe "list_all_boards/0" do
    test "returns boards ordered by position" do
      {:ok, b1} = Content.create_board(%{name: "Board A", slug: "board-a-#{System.unique_integer([:positive])}", position: 2})
      {:ok, b2} = Content.create_board(%{name: "Board B", slug: "board-b-#{System.unique_integer([:positive])}", position: 1})

      boards = Content.list_all_boards()
      ids = Enum.map(boards, & &1.id)
      assert Enum.find_index(ids, &(&1 == b2.id)) < Enum.find_index(ids, &(&1 == b1.id))
    end
  end

  describe "create_board/1" do
    test "creates a board with valid attrs" do
      attrs = %{name: "New Board", slug: "new-board-#{System.unique_integer([:positive])}", description: "A test board"}
      {:ok, board} = Content.create_board(attrs)
      assert board.name == "New Board"
      assert board.visibility == "public"
    end

    test "fails without required fields" do
      {:error, changeset} = Content.create_board(%{})
      assert changeset.errors[:name]
      assert changeset.errors[:slug]
    end

    test "fails with duplicate slug" do
      slug = "dup-slug-#{System.unique_integer([:positive])}"
      {:ok, _} = Content.create_board(%{name: "First", slug: slug})
      {:error, changeset} = Content.create_board(%{name: "Second", slug: slug})
      assert changeset.errors[:slug]
    end
  end

  describe "update_board/2" do
    test "updates board name" do
      {:ok, board} = Content.create_board(%{name: "Old", slug: "update-test-#{System.unique_integer([:positive])}"})
      {:ok, updated} = Content.update_board(board, %{name: "New Name"})
      assert updated.name == "New Name"
    end

    test "does not change slug" do
      slug = "immutable-slug-#{System.unique_integer([:positive])}"
      {:ok, board} = Content.create_board(%{name: "Board", slug: slug})
      {:ok, updated} = Content.update_board(board, %{name: "Changed"})
      assert updated.slug == slug
    end
  end

  describe "delete_board/1" do
    test "deletes a board without articles" do
      {:ok, board} = Content.create_board(%{name: "Deletable", slug: "del-#{System.unique_integer([:positive])}"})
      {:ok, deleted} = Content.delete_board(board)
      assert deleted.id == board.id
    end

    test "returns error when board has articles", %{user: user} do
      {:ok, board} = Content.create_board(%{name: "Busy", slug: "busy-#{System.unique_integer([:positive])}"})

      {:ok, article} =
        %Article{}
        |> Article.changeset(%{
          title: "Test Article",
          body: "Body",
          slug: "art-#{System.unique_integer([:positive])}",
          user_id: user.id
        })
        |> Repo.insert()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      Repo.insert!(%BoardArticle{board_id: board.id, article_id: article.id, inserted_at: now, updated_at: now})

      assert {:error, :has_articles} = Content.delete_board(board)
    end
  end

  describe "delete_board/1 with child boards" do
    test "returns error when board has children" do
      {:ok, parent} = Content.create_board(%{name: "Parent", slug: "parent-#{System.unique_integer([:positive])}"})
      {:ok, _child} = Content.create_board(%{name: "Child", slug: "child-#{System.unique_integer([:positive])}", parent_id: parent.id})

      assert {:error, :has_children} = Content.delete_board(parent)
    end
  end

  describe "update_board/2 circular parent" do
    test "rejects self as parent" do
      {:ok, board} = Content.create_board(%{name: "Self", slug: "self-ref-#{System.unique_integer([:positive])}"})
      {:error, changeset} = Content.update_board(board, %{parent_id: board.id})
      assert changeset.errors[:parent_id]
    end

    test "rejects indirect cycle (A → B → A)" do
      {:ok, a} = Content.create_board(%{name: "A", slug: "cycle-a-#{System.unique_integer([:positive])}"})
      {:ok, b} = Content.create_board(%{name: "B", slug: "cycle-b-#{System.unique_integer([:positive])}", parent_id: a.id})

      {:error, changeset} = Content.update_board(a, %{parent_id: b.id})
      assert changeset.errors[:parent_id]
    end

    test "rejects deeper cycle (A → B → C → A)" do
      {:ok, a} = Content.create_board(%{name: "A", slug: "deep-a-#{System.unique_integer([:positive])}"})
      {:ok, b} = Content.create_board(%{name: "B", slug: "deep-b-#{System.unique_integer([:positive])}", parent_id: a.id})
      {:ok, c} = Content.create_board(%{name: "C", slug: "deep-c-#{System.unique_integer([:positive])}", parent_id: b.id})

      {:error, changeset} = Content.update_board(a, %{parent_id: c.id})
      assert changeset.errors[:parent_id]
    end
  end

  describe "board field length validation" do
    test "rejects name over 100 characters" do
      long_name = String.duplicate("a", 101)
      {:error, changeset} = Content.create_board(%{name: long_name, slug: "long-#{System.unique_integer([:positive])}"})
      assert changeset.errors[:name]
    end

    test "rejects description over 1000 characters" do
      long_desc = String.duplicate("a", 1001)
      {:error, changeset} = Content.create_board(%{name: "OK", slug: "desc-#{System.unique_integer([:positive])}", description: long_desc})
      assert changeset.errors[:description]
    end
  end

  describe "change_board/2" do
    test "returns a changeset" do
      changeset = Content.change_board()
      assert %Ecto.Changeset{} = changeset
    end
  end
end
