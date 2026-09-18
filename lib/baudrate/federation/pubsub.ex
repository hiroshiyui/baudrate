defmodule Baudrate.Federation.PubSub do
  @moduledoc """
  Centralized PubSub helpers for real-time federation feed updates.

  ## Topics

    * `"timeline:user:<user_id>"` — user-level timeline events (new timeline item created)

  ## Messages

  All messages are tuples of `{event_atom, %{id_key: id}}`. Only IDs are
  broadcast — no user content travels through PubSub. Subscribers re-fetch
  data from the database to respect access controls.

  ## Usage

      # In a LiveView mount:
      if connected?(socket), do: FederationPubSub.subscribe_user_timeline(user.id)

      # In a Federation context mutation:
      FederationPubSub.broadcast_to_user_timeline(user_id, :timeline_item_created, %{timeline_item_id: id})
  """

  @pubsub Baudrate.PubSub

  @doc "Returns the PubSub topic string for a user's timeline."
  def user_timeline_topic(user_id), do: "timeline:user:#{user_id}"

  @doc "Subscribes the caller to timeline events for the given user."
  def subscribe_user_timeline(user_id),
    do: Phoenix.PubSub.subscribe(@pubsub, user_timeline_topic(user_id))

  @doc "Broadcasts an event to all subscribers of a user's timeline topic."
  def broadcast_to_user_timeline(user_id, event, payload),
    do: Phoenix.PubSub.broadcast(@pubsub, user_timeline_topic(user_id), {event, payload})
end
