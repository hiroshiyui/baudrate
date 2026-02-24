defmodule Baudrate.Content.BoardAncestorsTest do
  use Baudrate.DataCase

  alias Baudrate.Content

  describe "board_ancestors/1" do
    test "returns just the board for a root board" do
      {:ok, board} =
        Content.create_board(%{name: "Root", slug: "root-#{System.unique_integer([:positive])}"})

      ancestors = Content.board_ancestors(board)
      assert length(ancestors) == 1
      assert hd(ancestors).id == board.id
    end

    test "returns parent then child for single-level hierarchy" do
      {:ok, parent} =
        Content.create_board(%{
          name: "Parent",
          slug: "parent-#{System.unique_integer([:positive])}"
        })

      {:ok, child} =
        Content.create_board(%{
          name: "Child",
          slug: "child-#{System.unique_integer([:positive])}",
          parent_id: parent.id
        })

      ancestors = Content.board_ancestors(child)
      assert length(ancestors) == 2
      assert Enum.at(ancestors, 0).id == parent.id
      assert Enum.at(ancestors, 1).id == child.id
    end

    test "returns full chain for multi-level hierarchy" do
      {:ok, root} =
        Content.create_board(%{name: "Root", slug: "root-#{System.unique_integer([:positive])}"})

      {:ok, mid} =
        Content.create_board(%{
          name: "Mid",
          slug: "mid-#{System.unique_integer([:positive])}",
          parent_id: root.id
        })

      {:ok, leaf} =
        Content.create_board(%{
          name: "Leaf",
          slug: "leaf-#{System.unique_integer([:positive])}",
          parent_id: mid.id
        })

      ancestors = Content.board_ancestors(leaf)
      assert length(ancestors) == 3
      assert Enum.at(ancestors, 0).id == root.id
      assert Enum.at(ancestors, 1).id == mid.id
      assert Enum.at(ancestors, 2).id == leaf.id
    end
  end

  describe "list_visible_sub_boards/2" do
    test "returns only sub-boards visible to the given user" do
      {:ok, parent} =
        Content.create_board(%{
          name: "Parent",
          slug: "parent-#{System.unique_integer([:positive])}"
        })

      {:ok, _pub} =
        Content.create_board(%{
          name: "Public Child",
          slug: "pub-#{System.unique_integer([:positive])}",
          parent_id: parent.id,
          min_role_to_view: "guest"
        })

      {:ok, _priv} =
        Content.create_board(%{
          name: "Users Only Child",
          slug: "priv-#{System.unique_integer([:positive])}",
          parent_id: parent.id,
          min_role_to_view: "user"
        })

      # Guest (nil user) sees only public child
      visible_subs = Content.list_visible_sub_boards(parent, nil)
      assert length(visible_subs) == 1
      assert hd(visible_subs).name == "Public Child"
    end
  end
end
