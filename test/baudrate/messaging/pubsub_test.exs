defmodule Baudrate.Messaging.PubSubTest do
  use ExUnit.Case, async: true

  alias Baudrate.Messaging.PubSub, as: MessagingPubSub

  describe "user_topic/1" do
    test "returns expected topic string" do
      assert MessagingPubSub.user_topic(42) == "dm:user:42"
    end
  end

  describe "conversation_topic/1" do
    test "returns expected topic string" do
      assert MessagingPubSub.conversation_topic(7) == "dm:conversation:7"
    end
  end
end
