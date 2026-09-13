defmodule BaudrateWeb.CommentComponentsTest do
  use BaudrateWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias BaudrateWeb.CommentComponents

  @comment %{id: 10, user_id: 1}
  @viewer %{id: 2}

  describe "comment_like_button/1" do
    test "is a toggle button with a stable name and aria-pressed=false" do
      html =
        render_component(&CommentComponents.comment_like_button/1,
          comment: @comment,
          current_user: @viewer,
          comment_liked_ids: MapSet.new(),
          comment_like_counts: %{}
        )

      assert html =~ ~s(aria-pressed="false")
      assert html =~ ~s(aria-label="Like")
    end

    test "reports aria-pressed=true when liked and keeps the visible count" do
      html =
        render_component(&CommentComponents.comment_like_button/1,
          comment: @comment,
          current_user: @viewer,
          comment_liked_ids: MapSet.new([10]),
          comment_like_counts: %{10 => 3}
        )

      assert html =~ ~s(aria-pressed="true")
      assert html =~ ~s(aria-label="Like")
      assert html =~ ~r/class="comment-like-count">3</
    end
  end

  describe "comment_boost_button/1" do
    test "is a toggle button with aria-pressed reflecting boost state" do
      html =
        render_component(&CommentComponents.comment_boost_button/1,
          comment: @comment,
          current_user: @viewer,
          comment_boosted_ids: MapSet.new([10]),
          comment_boost_counts: %{10 => 1}
        )

      assert html =~ ~s(aria-pressed="true")
      assert html =~ ~s(aria-label="Boost")
    end

    test "renders no toggle for the comment author" do
      html =
        render_component(&CommentComponents.comment_boost_button/1,
          comment: @comment,
          current_user: %{id: 1},
          comment_boosted_ids: MapSet.new(),
          comment_boost_counts: %{}
        )

      refute html =~ "aria-pressed"
    end
  end
end
