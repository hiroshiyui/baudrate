defmodule Baudrate.Content.BoardCacheTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.BoardCache

  # The cache is started by the application but tests bypass it by default
  # (settings_cache_enabled: false). We test the cache module directly here
  # by calling refresh() from within the sandbox transaction, then reading
  # from the ETS table.

  setup do
    # Refresh cache from this test process so it sees sandbox data
    BoardCache.refresh()
    on_exit(fn -> BoardCache.refresh() end)
    :ok
  end

  defp create_board!(attrs) do
    {:ok, board} = Content.create_board(attrs)
    # Refresh cache to pick up the new board
    BoardCache.refresh()
    board
  end

  describe "get/1" do
    test "returns {:ok, board} for existing board" do
      board = create_board!(%{name: "Cache Test", slug: "cache-test-#{System.unique_integer([:positive])}"})
      assert {:ok, cached} = BoardCache.get(board.id)
      assert cached.id == board.id
      assert cached.name == "Cache Test"
    end

    test "returns {:error, :not_found} for unknown ID" do
      assert {:error, :not_found} = BoardCache.get(999_999)
    end
  end

  describe "get_by_slug/1" do
    test "returns board for existing slug" do
      slug = "slug-test-#{System.unique_integer([:positive])}"
      board = create_board!(%{name: "Slug Board", slug: slug})
      cached = BoardCache.get_by_slug(slug)
      assert cached.id == board.id
    end

    test "returns nil for unknown slug" do
      assert is_nil(BoardCache.get_by_slug("nonexistent-slug"))
    end
  end

  describe "top_boards/0" do
    test "returns root boards sorted by position" do
      slug_a = "top-a-#{System.unique_integer([:positive])}"
      slug_b = "top-b-#{System.unique_integer([:positive])}"
      board_b = create_board!(%{name: "Board B", slug: slug_b, position: 2})
      board_a = create_board!(%{name: "Board A", slug: slug_a, position: 1})

      top = BoardCache.top_boards()
      ids = Enum.map(top, & &1.id)

      assert board_a.id in ids
      assert board_b.id in ids

      # board_a (position 1) should come before board_b (position 2)
      idx_a = Enum.find_index(top, &(&1.id == board_a.id))
      idx_b = Enum.find_index(top, &(&1.id == board_b.id))
      assert idx_a < idx_b
    end

    test "excludes child boards" do
      parent = create_board!(%{name: "Parent", slug: "parent-#{System.unique_integer([:positive])}"})
      child = create_board!(%{name: "Child", slug: "child-#{System.unique_integer([:positive])}", parent_id: parent.id})

      top_ids = Enum.map(BoardCache.top_boards(), & &1.id)
      assert parent.id in top_ids
      refute child.id in top_ids
    end
  end

  describe "sub_boards/1" do
    test "returns children sorted by position" do
      parent = create_board!(%{name: "Parent", slug: "sub-parent-#{System.unique_integer([:positive])}"})

      child_b =
        create_board!(%{
          name: "Child B",
          slug: "sub-child-b-#{System.unique_integer([:positive])}",
          parent_id: parent.id,
          position: 2
        })

      child_a =
        create_board!(%{
          name: "Child A",
          slug: "sub-child-a-#{System.unique_integer([:positive])}",
          parent_id: parent.id,
          position: 1
        })

      children = BoardCache.sub_boards(parent.id)
      assert length(children) == 2
      assert Enum.at(children, 0).id == child_a.id
      assert Enum.at(children, 1).id == child_b.id
    end

    test "returns empty list for leaf boards" do
      leaf = create_board!(%{name: "Leaf", slug: "leaf-#{System.unique_integer([:positive])}"})
      assert BoardCache.sub_boards(leaf.id) == []
    end

    test "returns empty list for unknown parent ID" do
      assert BoardCache.sub_boards(999_999) == []
    end
  end

  describe "ancestors/1" do
    test "returns [board] for root board" do
      root = create_board!(%{name: "Root", slug: "anc-root-#{System.unique_integer([:positive])}"})
      chain = BoardCache.ancestors(root.id)
      assert length(chain) == 1
      assert hd(chain).id == root.id
    end

    test "returns correct ancestor chain from root to board" do
      root = create_board!(%{name: "Root", slug: "anc-r-#{System.unique_integer([:positive])}"})

      mid =
        create_board!(%{
          name: "Mid",
          slug: "anc-m-#{System.unique_integer([:positive])}",
          parent_id: root.id
        })

      leaf =
        create_board!(%{
          name: "Leaf",
          slug: "anc-l-#{System.unique_integer([:positive])}",
          parent_id: mid.id
        })

      chain = BoardCache.ancestors(leaf.id)
      assert length(chain) == 3
      assert Enum.map(chain, & &1.id) == [root.id, mid.id, leaf.id]
    end

    test "returns empty list for unknown board" do
      assert BoardCache.ancestors(999_999) == []
    end
  end

  describe "refresh/0" do
    test "reflects newly created boards" do
      assert {:error, :not_found} = BoardCache.get(999_999)

      slug = "refresh-new-#{System.unique_integer([:positive])}"
      {:ok, board} = Content.create_board(%{name: "New Board", slug: slug})
      BoardCache.refresh()

      assert {:ok, cached} = BoardCache.get(board.id)
      assert cached.slug == slug
    end

    test "reflects updated boards" do
      board = create_board!(%{name: "Original", slug: "refresh-upd-#{System.unique_integer([:positive])}"})

      {:ok, _updated} = Content.update_board(board, %{name: "Updated Name"})
      BoardCache.refresh()

      assert {:ok, cached} = BoardCache.get(board.id)
      assert cached.name == "Updated Name"
    end

    test "reflects deleted boards" do
      board = create_board!(%{name: "ToDelete", slug: "refresh-del-#{System.unique_integer([:positive])}"})
      assert {:ok, _cached} = BoardCache.get(board.id)

      {:ok, _} = Content.delete_board(board)
      BoardCache.refresh()

      assert {:error, :not_found} = BoardCache.get(board.id)
    end
  end
end
