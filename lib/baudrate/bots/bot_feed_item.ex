defmodule Baudrate.Bots.BotFeedItem do
  @moduledoc """
  Tracks which feed item GUIDs have already been posted by a bot.

  Used for deduplication: before creating an article for a feed entry,
  the worker checks `bot_feed_items` for `(bot_id, guid)`. If a record
  exists, the entry is skipped.
  """

  use Ecto.Schema

  alias Baudrate.Bots.Bot
  alias Baudrate.Content.Article

  schema "bot_feed_items" do
    field :guid, :string

    belongs_to :bot, Bot
    belongs_to :article, Article

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
