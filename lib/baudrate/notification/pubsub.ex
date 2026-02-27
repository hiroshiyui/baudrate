defmodule Baudrate.Notification.PubSub do
  @moduledoc """
  Centralized PubSub helpers for real-time notification updates.

  Subscribers receive lightweight event tuples — only IDs are broadcast,
  never full structs. Consumers should re-fetch from the database.

  ## Events

    * `{:notification_created, %{notification_id: id}}` — new notification
    * `{:notification_read, %{notification_id: id}}` — single notification marked read
    * `{:notifications_all_read, %{user_id: id}}` — all notifications marked read
  """

  @pubsub Baudrate.PubSub

  @doc "Returns the PubSub topic string for a user's notification events."
  def user_topic(user_id), do: "notifications:user:#{user_id}"

  @doc "Subscribes the caller to a user's notification events."
  def subscribe_user(user_id),
    do: Phoenix.PubSub.subscribe(@pubsub, user_topic(user_id))

  @doc "Broadcasts an event to all subscribers of a user's notification topic."
  def broadcast_to_user(user_id, event, payload),
    do: Phoenix.PubSub.broadcast(@pubsub, user_topic(user_id), {event, payload})
end
