defmodule Baudrate.Notification.PubSubTest do
  use ExUnit.Case, async: true

  alias Baudrate.Notification.PubSub

  describe "user_topic/1" do
    test "returns topic string with user ID" do
      assert PubSub.user_topic(42) == "notifications:user:42"
    end
  end

  describe "subscribe_user/1" do
    test "subscribes to a user's notification topic" do
      :ok = PubSub.subscribe_user(123)

      PubSub.broadcast_to_user(123, :notification_created, %{notification_id: 1})

      assert_receive {:notification_created, %{notification_id: 1}}
    end
  end

  describe "broadcast_to_user/3" do
    test "broadcasts notification_created event" do
      :ok = PubSub.subscribe_user(456)

      PubSub.broadcast_to_user(456, :notification_created, %{notification_id: 10})

      assert_receive {:notification_created, %{notification_id: 10}}
    end

    test "broadcasts notification_read event" do
      :ok = PubSub.subscribe_user(456)

      PubSub.broadcast_to_user(456, :notification_read, %{notification_id: 10})

      assert_receive {:notification_read, %{notification_id: 10}}
    end

    test "broadcasts notifications_all_read event" do
      :ok = PubSub.subscribe_user(456)

      PubSub.broadcast_to_user(456, :notifications_all_read, %{user_id: 456})

      assert_receive {:notifications_all_read, %{user_id: 456}}
    end

    test "does not deliver to other user topics" do
      :ok = PubSub.subscribe_user(100)

      PubSub.broadcast_to_user(200, :notification_created, %{notification_id: 5})

      refute_receive {:notification_created, _}
    end
  end
end
