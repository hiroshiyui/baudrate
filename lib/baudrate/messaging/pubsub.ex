defmodule Baudrate.Messaging.PubSub do
  @moduledoc """
  Centralized PubSub helpers for real-time direct message updates.

  ## Topics

    * `"dm:user:<user_id>"` — user-level events (new conversation, new message
      in any conversation, unread count changes)
    * `"dm:conversation:<conversation_id>"` — conversation-level events
      (new message, message deleted)

  ## Messages

  All messages are tuples of `{event_atom, %{key: id}}`. Only IDs are
  broadcast — no message content travels through PubSub. Subscribers
  re-fetch data from the database.

  ## Usage

      # In a LiveView mount:
      if connected?(socket), do: MessagingPubSub.subscribe_user(user.id)

      # In the Messaging context after a mutation:
      MessagingPubSub.broadcast_to_user(user_id, :dm_received, %{conversation_id: id})
  """

  @pubsub Baudrate.PubSub

  @doc "Returns the PubSub topic string for a user's DM events."
  def user_topic(user_id), do: "dm:user:#{user_id}"

  @doc "Returns the PubSub topic string for a conversation."
  def conversation_topic(conversation_id), do: "dm:conversation:#{conversation_id}"

  @doc "Subscribes the caller to user-level DM events."
  def subscribe_user(user_id),
    do: Phoenix.PubSub.subscribe(@pubsub, user_topic(user_id))

  @doc "Subscribes the caller to conversation-level events."
  def subscribe_conversation(conversation_id),
    do: Phoenix.PubSub.subscribe(@pubsub, conversation_topic(conversation_id))

  @doc "Broadcasts an event to all subscribers of a user's DM topic."
  def broadcast_to_user(user_id, event, payload),
    do: Phoenix.PubSub.broadcast(@pubsub, user_topic(user_id), {event, payload})

  @doc "Broadcasts an event to all subscribers of a conversation topic."
  def broadcast_to_conversation(conversation_id, event, payload),
    do: Phoenix.PubSub.broadcast(@pubsub, conversation_topic(conversation_id), {event, payload})
end
