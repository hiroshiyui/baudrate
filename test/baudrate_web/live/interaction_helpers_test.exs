defmodule BaudrateWeb.InteractionHelpersTest do
  use Baudrate.DataCase

  alias BaudrateWeb.InteractionHelpers

  defp build_socket(assigns) do
    defaults = %{
      __changed__: %{},
      flash: %{}
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(defaults, assigns)}
  end

  describe "handle_toggle_with_counts/7" do
    test "toggles item into MapSet and updates count on success" do
      socket =
        build_socket(%{
          current_user: %{id: 1},
          liked_ids: MapSet.new(),
          like_counts: %{}
        })

      toggle_fn = fn _user_id, _item_id -> {:ok, :toggled} end
      count_fn = fn [item_id] -> %{item_id => 5} end

      opts = [
        self_error: :self_like,
        self_message: "Cannot like own.",
        fail_message: "Failed."
      ]

      assert {:noreply, socket} =
               InteractionHelpers.handle_toggle_with_counts(
                 socket,
                 "42",
                 toggle_fn,
                 count_fn,
                 :liked_ids,
                 :like_counts,
                 opts
               )

      assert MapSet.member?(socket.assigns.liked_ids, 42)
      assert socket.assigns.like_counts[42] == 5
    end

    test "toggles item out of MapSet when already present" do
      socket =
        build_socket(%{
          current_user: %{id: 1},
          liked_ids: MapSet.new([42]),
          like_counts: %{42 => 1}
        })

      toggle_fn = fn _user_id, _item_id -> {:ok, :toggled} end
      count_fn = fn [item_id] -> %{item_id => 0} end

      opts = [
        self_error: :self_like,
        self_message: "Cannot like own.",
        fail_message: "Failed."
      ]

      assert {:noreply, socket} =
               InteractionHelpers.handle_toggle_with_counts(
                 socket,
                 "42",
                 toggle_fn,
                 count_fn,
                 :liked_ids,
                 :like_counts,
                 opts
               )

      refute MapSet.member?(socket.assigns.liked_ids, 42)
      assert socket.assigns.like_counts[42] == 0
    end

    test "shows self-error flash on self-interaction" do
      socket =
        build_socket(%{
          current_user: %{id: 1},
          liked_ids: MapSet.new(),
          like_counts: %{}
        })

      toggle_fn = fn _user_id, _item_id -> {:error, :self_like} end
      count_fn = fn _ -> %{} end

      opts = [
        self_error: :self_like,
        self_message: "Cannot like own.",
        fail_message: "Failed."
      ]

      assert {:noreply, socket} =
               InteractionHelpers.handle_toggle_with_counts(
                 socket,
                 "42",
                 toggle_fn,
                 count_fn,
                 :liked_ids,
                 :like_counts,
                 opts
               )

      assert socket.assigns.flash["error"] == "Cannot like own."
    end

    test "shows fail flash on generic error" do
      socket =
        build_socket(%{
          current_user: %{id: 1},
          liked_ids: MapSet.new(),
          like_counts: %{}
        })

      toggle_fn = fn _user_id, _item_id -> {:error, :not_found} end
      count_fn = fn _ -> %{} end

      opts = [
        self_error: :self_like,
        self_message: "Cannot like own.",
        fail_message: "Something went wrong."
      ]

      assert {:noreply, socket} =
               InteractionHelpers.handle_toggle_with_counts(
                 socket,
                 "42",
                 toggle_fn,
                 count_fn,
                 :liked_ids,
                 :like_counts,
                 opts
               )

      assert socket.assigns.flash["error"] == "Something went wrong."
    end

    test "returns noreply with unchanged socket on invalid ID" do
      socket =
        build_socket(%{
          current_user: %{id: 1},
          liked_ids: MapSet.new(),
          like_counts: %{}
        })

      toggle_fn = fn _user_id, _item_id -> {:ok, :toggled} end
      count_fn = fn _ -> %{} end

      opts = [
        self_error: :self_like,
        self_message: "Cannot like own.",
        fail_message: "Failed."
      ]

      assert {:noreply, ^socket} =
               InteractionHelpers.handle_toggle_with_counts(
                 socket,
                 "not_a_number",
                 toggle_fn,
                 count_fn,
                 :liked_ids,
                 :like_counts,
                 opts
               )
    end
  end

  describe "handle_toggle_mapset/5" do
    test "toggles item into MapSet on success" do
      socket =
        build_socket(%{
          current_user: %{id: 1},
          feed_liked_ids: MapSet.new()
        })

      toggle_fn = fn _user, _item_id -> {:ok, :toggled} end

      assert {:noreply, socket} =
               InteractionHelpers.handle_toggle_mapset(
                 socket,
                 "99",
                 toggle_fn,
                 :feed_liked_ids,
                 "Failed."
               )

      assert MapSet.member?(socket.assigns.feed_liked_ids, 99)
    end

    test "toggles item out of MapSet when already present" do
      socket =
        build_socket(%{
          current_user: %{id: 1},
          feed_liked_ids: MapSet.new([99])
        })

      toggle_fn = fn _user, _item_id -> {:ok, :toggled} end

      assert {:noreply, socket} =
               InteractionHelpers.handle_toggle_mapset(
                 socket,
                 "99",
                 toggle_fn,
                 :feed_liked_ids,
                 "Failed."
               )

      refute MapSet.member?(socket.assigns.feed_liked_ids, 99)
    end

    test "shows error flash on failure" do
      socket =
        build_socket(%{
          current_user: %{id: 1},
          feed_liked_ids: MapSet.new()
        })

      toggle_fn = fn _user, _item_id -> {:error, :not_found} end

      assert {:noreply, socket} =
               InteractionHelpers.handle_toggle_mapset(
                 socket,
                 "99",
                 toggle_fn,
                 :feed_liked_ids,
                 "Something failed."
               )

      assert socket.assigns.flash["error"] == "Something failed."
    end

    test "returns noreply with unchanged socket on invalid ID" do
      socket =
        build_socket(%{
          current_user: %{id: 1},
          feed_liked_ids: MapSet.new()
        })

      toggle_fn = fn _user, _item_id -> {:ok, :toggled} end

      assert {:noreply, ^socket} =
               InteractionHelpers.handle_toggle_mapset(
                 socket,
                 "abc",
                 toggle_fn,
                 :feed_liked_ids,
                 "Failed."
               )
    end
  end

  describe "opts helpers" do
    test "article_like_opts returns expected keys" do
      opts = InteractionHelpers.article_like_opts()
      assert opts[:self_error] == :self_like
      assert is_binary(opts[:self_message])
      assert is_binary(opts[:fail_message])
    end

    test "article_boost_opts returns expected keys" do
      opts = InteractionHelpers.article_boost_opts()
      assert opts[:self_error] == :self_boost
      assert is_binary(opts[:self_message])
      assert is_binary(opts[:fail_message])
    end

    test "comment_like_opts returns expected keys" do
      opts = InteractionHelpers.comment_like_opts()
      assert opts[:self_error] == :self_like
    end

    test "comment_boost_opts returns expected keys" do
      opts = InteractionHelpers.comment_boost_opts()
      assert opts[:self_error] == :self_boost
    end
  end
end
