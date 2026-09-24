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
    * `favicon_fail_count` — consecutive automatic favicon fetch failure counter;
      auto-fetch is paused when this reaches 3 (manual "Refresh Favicon" always works
      and resets the counter on success)
    * `include_patterns` / `exclude_patterns` — `%{"kind" => "word" | "substring",
      "pattern" => …}` matched against an entry's title and text with
      `Baudrate.Moderation.PatternMatcher`. An entry is posted only if it matches
      no exclude pattern and, when there are include patterns, at least one of them
    * `first_fetch_limit` — how many of the newest entries the first successful
      fetch posts; the rest of the backlog is recorded as seen
    * `etag` / `last_modified` — the last 200 response's validators, sent back on
      the next fetch so an unchanged feed answers 304

  A bot is switched off after `max_failures/0` failed fetches in a row
  (`Baudrate.Bots.mark_fetch_error/2`).

  Admins write patterns one per line (`include_text` / `exclude_text`): a line
  with a `*` is a substring pattern (`*rust*` matches inside a word), any other
  line a whole-word pattern.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Moderation.ContentFilter
  alias Baudrate.Setup.User

  @max_failures 10
  @max_patterns 50
  @max_first_fetch_limit 100

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
    field :favicon_fail_count, :integer, default: 0
    field :include_patterns, {:array, :map}, default: []
    field :exclude_patterns, {:array, :map}, default: []
    field :first_fetch_limit, :integer, default: 5
    field :etag, :string
    field :last_modified, :string

    # The admin form's one-pattern-per-line text; parsed into the two lists.
    field :include_text, :string, virtual: true
    field :exclude_text, :string, virtual: true

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc "Failed fetches in a row after which a bot is switched off."
  def max_failures, do: @max_failures

  @doc "The most include (or exclude) patterns one bot may keep."
  def max_patterns, do: @max_patterns

  @doc "The largest first-fetch limit."
  def max_first_fetch_limit, do: @max_first_fetch_limit

  @doc "Changeset for creating a new bot."
  def create_changeset(bot, attrs) do
    bot
    |> cast(attrs, [
      :user_id,
      :feed_url,
      :board_ids,
      :fetch_interval_minutes,
      :active,
      :first_fetch_limit
    ])
    |> validate_required([:user_id, :feed_url])
    |> validate_feed_url()
    |> validate_number(:fetch_interval_minutes, greater_than: 0, less_than_or_equal_to: 1440)
    |> validate_first_fetch_limit()
    |> cast_patterns(attrs)
    |> assoc_constraint(:user)
    |> unique_constraint(:user_id)
  end

  @doc """
  Changeset for updating a bot's configuration.

  A new feed URL is a new feed: the validators and `last_fetched_at` are
  cleared, so the next fetch is unconditional and counts as a first fetch.
  Switching a bot back on clears its error count and fetches at once, or a
  bot switched off after `max_failures/0` failures would be switched off
  again by the next one.
  """
  def update_changeset(bot, attrs) do
    bot
    |> cast(attrs, [
      :feed_url,
      :board_ids,
      :fetch_interval_minutes,
      :active,
      :first_fetch_limit
    ])
    |> validate_required([:feed_url])
    |> validate_feed_url()
    |> validate_number(:fetch_interval_minutes, greater_than: 0, less_than_or_equal_to: 1440)
    |> validate_first_fetch_limit()
    |> cast_patterns(attrs)
    |> reset_for_new_feed()
    |> reset_on_reactivation()
  end

  @doc """
  The admin form's text for a pattern list: one pattern per line, a
  substring pattern written with its `*`s.
  """
  @spec patterns_text([map()] | nil) :: String.t()
  def patterns_text(nil), do: ""
  def patterns_text(patterns), do: Enum.map_join(patterns, "\n", & &1["pattern"])

  @doc """
  Parses the admin form's text into patterns: one per line, blank lines
  ignored, a line with a `*` a substring pattern and any other a word
  pattern, each in `ContentFilter.normalize_text/1`'s form.
  """
  @spec parse_patterns(String.t() | nil) :: [map()]
  def parse_patterns(nil), do: []

  def parse_patterns(text) when is_binary(text) do
    text
    |> String.split(~r/\R/u)
    |> Enum.map(&ContentFilter.normalize_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn pattern ->
      kind = if String.contains?(pattern, "*"), do: "substring", else: "word"
      %{"kind" => kind, "pattern" => pattern}
    end)
    |> Enum.uniq()
  end

  defp validate_first_fetch_limit(changeset) do
    validate_number(changeset, :first_fetch_limit,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_first_fetch_limit
    )
  end

  # `empty_values: []` keeps a cleared textarea as "" rather than nil, so
  # clearing every pattern is a change and not "field not sent".
  defp cast_patterns(changeset, attrs) do
    changeset
    |> cast(attrs, [:include_text, :exclude_text], empty_values: [])
    |> put_patterns(:include_text, :include_patterns)
    |> put_patterns(:exclude_text, :exclude_patterns)
  end

  defp put_patterns(changeset, text_field, list_field) do
    case fetch_change(changeset, text_field) do
      {:ok, text} ->
        patterns = parse_patterns(text)

        case patterns_error(patterns) do
          nil -> put_change(changeset, list_field, patterns)
          {message, keys} -> add_error(changeset, text_field, message, keys)
        end

      :error ->
        changeset
    end
  end

  # The messages are the `errors` domain's (priv/gettext/errors.pot), so each
  # names the offending line through a binding rather than by interpolation.
  defp patterns_error(patterns) when length(patterns) > @max_patterns,
    do: {"may hold at most %{max} patterns", max: @max_patterns}

  defp patterns_error(patterns) do
    max = ContentFilter.max_pattern_length()

    Enum.find_value(patterns, fn %{"kind" => kind, "pattern" => pattern} ->
      cond do
        String.length(pattern) > max ->
          {"\"%{pattern}\" is longer than %{max} characters", pattern: pattern, max: max}

        ContentFilter.pattern_error(kind, pattern) == "has no letters or numbers" ->
          {"\"%{pattern}\" has no letters or numbers", pattern: pattern}

        ContentFilter.pattern_error(kind, pattern) ->
          {"\"%{pattern}\" may hold only letters, numbers and *", pattern: pattern}

        true ->
          nil
      end
    end)
  end

  defp reset_on_reactivation(changeset) do
    if changeset.data.active == false and get_change(changeset, :active) == true do
      change(changeset, error_count: 0, next_fetch_at: nil)
    else
      changeset
    end
  end

  defp reset_for_new_feed(changeset) do
    if changed?(changeset, :feed_url) do
      change(changeset, etag: nil, last_modified: nil, last_fetched_at: nil, next_fetch_at: nil)
    else
      changeset
    end
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
