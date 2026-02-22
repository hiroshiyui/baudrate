defmodule Baudrate.Content.PubSub do
  @moduledoc """
  Centralized PubSub helpers for real-time content updates.

  ## Topics

    * `"board:<board_id>"` — board-level events (article created, deleted,
      updated, pinned, unpinned, locked, unlocked)
    * `"article:<article_id>"` — article-level events (comment created,
      comment deleted, article deleted, article updated)

  ## Messages

  All messages are tuples of `{event_atom, %{id_key: id}}`. Only IDs are
  broadcast — no user content travels through PubSub. Subscribers re-fetch
  data from the database to respect access controls.

  ## Usage

      # In a LiveView mount:
      if connected?(socket), do: ContentPubSub.subscribe_board(board.id)

      # In a Content context mutation:
      ContentPubSub.broadcast_to_board(board_id, :article_created, %{article_id: id})
  """

  @pubsub Baudrate.PubSub

  @doc "Returns the PubSub topic string for a board."
  def board_topic(board_id), do: "board:#{board_id}"

  @doc "Returns the PubSub topic string for an article."
  def article_topic(article_id), do: "article:#{article_id}"

  @doc "Subscribes the caller to board-level events."
  def subscribe_board(board_id),
    do: Phoenix.PubSub.subscribe(@pubsub, board_topic(board_id))

  @doc "Subscribes the caller to article-level events."
  def subscribe_article(article_id),
    do: Phoenix.PubSub.subscribe(@pubsub, article_topic(article_id))

  @doc "Broadcasts an event to all subscribers of a board topic."
  def broadcast_to_board(board_id, event, payload),
    do: Phoenix.PubSub.broadcast(@pubsub, board_topic(board_id), {event, payload})

  @doc "Broadcasts an event to all subscribers of an article topic."
  def broadcast_to_article(article_id, event, payload),
    do: Phoenix.PubSub.broadcast(@pubsub, article_topic(article_id), {event, payload})
end
