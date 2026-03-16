defmodule Baudrate.Bots.Bot do
  @moduledoc """
  Schema for bot accounts that periodically fetch RSS/Atom feeds.

  Each bot is backed by a user account (`is_bot: true`) and posts
  feed entries as articles to the configured target boards.

  ## Fields

    * `user_id` — 1:1 reference to the bot's user account
    * `feed_url` — URL of the RSS 2.0 or Atom 1.0 feed
    * `board_ids` — Postgres integer array of target board IDs
    * `fetch_interval_minutes` — how often to fetch (default 60)
    * `last_fetched_at` — timestamp of the last successful fetch
    * `next_fetch_at` — when to next fetch (nil = fetch immediately)
    * `active` — whether the bot is enabled
    * `error_count` — consecutive error counter; drives backoff
    * `last_error` — description of the most recent error
    * `avatar_refreshed_at` — when the site favicon was last fetched
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Setup.User

  schema "bots" do
    field :feed_url, :string
    field :board_ids, {:array, :integer}, default: []
    field :fetch_interval_minutes, :integer, default: 60
    field :last_fetched_at, :utc_datetime
    field :next_fetch_at, :utc_datetime
    field :active, :boolean, default: true
    field :error_count, :integer, default: 0
    field :last_error, :string
    field :avatar_refreshed_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a new bot."
  def create_changeset(bot, attrs) do
    bot
    |> cast(attrs, [
      :user_id,
      :feed_url,
      :board_ids,
      :fetch_interval_minutes,
      :active
    ])
    |> validate_required([:user_id, :feed_url])
    |> validate_feed_url()
    |> validate_number(:fetch_interval_minutes, greater_than: 0, less_than_or_equal_to: 1440)
    |> assoc_constraint(:user)
    |> unique_constraint(:user_id)
  end

  @doc "Changeset for updating a bot's configuration."
  def update_changeset(bot, attrs) do
    bot
    |> cast(attrs, [
      :feed_url,
      :board_ids,
      :fetch_interval_minutes,
      :active
    ])
    |> validate_required([:feed_url])
    |> validate_feed_url()
    |> validate_number(:fetch_interval_minutes, greater_than: 0, less_than_or_equal_to: 1440)
  end

  @doc "Changeset for deactivating a bot."
  def deactivate_changeset(bot) do
    bot
    |> change(active: false)
  end

  defp validate_feed_url(changeset) do
    changeset
    |> validate_length(:feed_url, max: 2048)
    |> validate_change(:feed_url, fn :feed_url, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [feed_url: "must be a valid HTTP or HTTPS URL"]
      end
    end)
  end
end
