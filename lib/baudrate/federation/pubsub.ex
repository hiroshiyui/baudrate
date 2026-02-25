defmodule Baudrate.Federation.PubSub do
  @moduledoc """
  Centralized PubSub helpers for real-time federation feed updates.

  ## Topics

    * `"feed:user:<user_id>"` — user-level feed events (new feed item created)

  ## Messages

  All messages are tuples of `{event_atom, %{id_key: id}}`. Only IDs are
  broadcast — no user content travels through PubSub. Subscribers re-fetch
  data from the database to respect access controls.

  ## Usage

      # In a LiveView mount:
      if connected?(socket), do: FederationPubSub.subscribe_user_feed(user.id)

      # In a Federation context mutation:
      FederationPubSub.broadcast_to_user_feed(user_id, :feed_item_created, %{feed_item_id: id})
  """

  @pubsub Baudrate.PubSub

  @doc "Returns the PubSub topic string for a user's feed."
  def user_feed_topic(user_id), do: "feed:user:#{user_id}"

  @doc "Subscribes the caller to feed events for the given user."
  def subscribe_user_feed(user_id),
    do: Phoenix.PubSub.subscribe(@pubsub, user_feed_topic(user_id))

  @doc "Broadcasts an event to all subscribers of a user's feed topic."
  def broadcast_to_user_feed(user_id, event, payload),
    do: Phoenix.PubSub.broadcast(@pubsub, user_feed_topic(user_id), {event, payload})
end
