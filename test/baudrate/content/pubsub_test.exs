defmodule Baudrate.Content.PubSubTest do
  use ExUnit.Case, async: true

  alias Baudrate.Content.PubSub, as: ContentPubSub

  describe "topic naming" do
    test "board_topic/1 formats topic string" do
      assert ContentPubSub.board_topic(42) == "board:42"
    end

    test "article_topic/1 formats topic string" do
      assert ContentPubSub.article_topic(99) == "article:99"
    end
  end

  describe "subscribe and broadcast" do
    test "subscribe_board + broadcast_to_board delivers message" do
      board_id = System.unique_integer([:positive])
      ContentPubSub.subscribe_board(board_id)

      ContentPubSub.broadcast_to_board(board_id, :article_created, %{article_id: 1})

      assert_receive {:article_created, %{article_id: 1}}
    end

    test "subscribe_article + broadcast_to_article delivers message" do
      article_id = System.unique_integer([:positive])
      ContentPubSub.subscribe_article(article_id)

      ContentPubSub.broadcast_to_article(article_id, :comment_created, %{comment_id: 5})

      assert_receive {:comment_created, %{comment_id: 5}}
    end

    test "messages are not received on unsubscribed topics" do
      board_id = System.unique_integer([:positive])
      other_board_id = System.unique_integer([:positive])

      ContentPubSub.subscribe_board(board_id)
      ContentPubSub.broadcast_to_board(other_board_id, :article_created, %{article_id: 1})

      refute_receive {:article_created, _}
    end
  end
end
