defmodule Baudrate.Bots.Fetcher do
  @moduledoc """
  One fetch of a bot's feed (Phase 7D): what to ask for, what to post, and
  the dry run that shows the second without doing it.

    * **Conditional GET.** The last 200 response's `ETag` and `Last-Modified`
      go back as `If-None-Match` / `If-Modified-Since`; a 304 is a successful
      fetch with nothing new. The `Accept` header names the feed types.
    * **What is posted** is decided by `plan/2`, one decision per entry:
      `:post`, `:seen` (already posted or recorded), `:excluded` (matched an
      exclude pattern), `:not_included` (the bot has include patterns and
      matched none) or `:backlog` (the first fetch posts only the newest
      `first_fetch_limit` entries).
    * **Every decision but `:post` and `:seen` is recorded** as a
      `bot_syndication_items` row with no article, so an entry is judged once:
      changing the filters later does not post an old entry, and the backlog
      skipped on the first fetch stays skipped.
    * **`preview/1`** fetches unconditionally (an admin wants to see the
      feed, not a 304), plans, and changes nothing: no article, no ledger
      row, no bot state.
  """

  require Logger

  alias Baudrate.Bots
  alias Baudrate.Bots.{Bot, SyndicationFeedParser, SyndicationFeedWorker}
  alias Baudrate.Federation.HTTPClient
  alias Baudrate.Moderation.PatternMatcher

  @accept "application/rss+xml, application/atom+xml, application/feed+json, " <>
            "application/rdf+xml;q=0.9, application/xml;q=0.9, text/xml;q=0.9, " <>
            "application/json;q=0.8, */*;q=0.5"

  @max_size 5 * 1024 * 1024
  @max_etag 512
  @max_last_modified 128

  @type decision :: :post | :seen | :excluded | :not_included | :backlog

  @doc """
  Fetches the feed, posts what `plan/2` says to post, records the rest, and
  marks the fetch a success or a failure. Called by the worker per due bot.
  """
  @spec run(Bot.t()) :: :ok
  def run(%Bot{} = bot) do
    case fetch(bot, conditional: true) do
      {:ok, :not_modified} ->
        Bots.mark_fetch_success(bot)

      {:ok, entries, validators} ->
        bot
        |> plan(entries)
        |> Enum.each(fn {entry, decision} -> apply_decision(bot, entry, decision) end)

        Bots.mark_fetch_success(bot, nil, validators)

      {:error, reason} ->
        error_msg = inspect(reason)

        Logger.warning(
          "bots.syndication_feed_worker: fetch failed for bot #{bot.id}: #{error_msg}"
        )

        Bots.mark_fetch_error(bot, error_msg)
    end

    :ok
  end

  @doc """
  The dry run: fetches the feed and returns what the next fetch would do with
  each entry, changing nothing. The entries are in feed order.
  """
  @spec preview(Bot.t()) :: {:ok, [{map(), decision()}]} | {:error, term()}
  def preview(%Bot{} = bot) do
    case fetch(bot, conditional: false) do
      {:ok, entries, _validators} -> {:ok, plan(bot, entries)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Decides what happens to each entry, in feed order. Pure apart from the
  ledger lookup behind `:seen`.

  The first-fetch limit counts only entries that would otherwise be posted,
  newest first by publication date (undated entries keep their feed order,
  after the dated ones).
  """
  @spec plan(Bot.t(), [map()]) :: [{map(), decision()}]
  def plan(%Bot{} = bot, entries) do
    includes = Enum.map(bot.include_patterns || [], &PatternMatcher.compile/1)
    excludes = Enum.map(bot.exclude_patterns || [], &PatternMatcher.compile/1)

    decided =
      Enum.map(entries, fn entry ->
        {entry, filter_decision(bot, entry, includes, excludes)}
      end)

    if is_nil(bot.last_fetched_at), do: limit_backlog(decided, bot), else: decided
  end

  defp filter_decision(bot, entry, includes, excludes) do
    cond do
      Bots.already_posted?(bot, entry.guid, entry.link) ->
        :seen

      excludes != [] and PatternMatcher.any_match?(excludes, texts(entry)) ->
        :excluded

      includes != [] and not PatternMatcher.any_match?(includes, texts(entry)) ->
        :not_included

      true ->
        :post
    end
  end

  defp texts(entry), do: [entry.title, PatternMatcher.text_of(entry.body)]

  defp limit_backlog(decided, bot) do
    keep =
      decided
      |> Enum.with_index()
      |> Enum.filter(fn {{_entry, decision}, _i} -> decision == :post end)
      |> Enum.sort_by(fn {{entry, _}, i} -> {newest_first(entry.published_at), i} end)
      |> Enum.take(bot.first_fetch_limit || 0)
      |> MapSet.new(fn {_, i} -> i end)

    decided
    |> Enum.with_index()
    |> Enum.map(fn
      {{entry, :post}, i} -> {entry, if(MapSet.member?(keep, i), do: :post, else: :backlog)}
      {pair, _i} -> pair
    end)
  end

  # Sorts dated entries newest first, then undated ones.
  defp newest_first(nil), do: {1, 0}
  defp newest_first(%DateTime{} = dt), do: {0, -DateTime.to_unix(dt, :microsecond)}

  defp apply_decision(bot, entry, :post), do: SyndicationFeedWorker.post_entry(bot, entry)
  defp apply_decision(_bot, _entry, :seen), do: :ok

  defp apply_decision(bot, entry, _skipped),
    do: Bots.record_syndication_item(bot, entry.guid, nil)

  @doc false
  # Public for tests: the request and its answer, without planning.
  @spec fetch(Bot.t(), keyword()) ::
          {:ok, :not_modified} | {:ok, [map()], map()} | {:error, term()}
  def fetch(%Bot{} = bot, opts) do
    headers = if opts[:conditional], do: conditional_headers(bot), else: []

    with :ok <- HTTPClient.validate_url(bot.feed_url),
         {:ok, response} <-
           HTTPClient.get_html(bot.feed_url,
             max_size: @max_size,
             accept: @accept,
             headers: headers,
             conditional: headers != []
           ) do
      case response do
        %{status: 304} ->
          {:ok, :not_modified}

        %{body: body, headers: resp_headers} ->
          with {:ok, entries} <- SyndicationFeedParser.parse(body) do
            {:ok, entries, validators(resp_headers)}
          end
      end
    end
  end

  defp conditional_headers(bot) do
    [
      bot.etag && {"if-none-match", bot.etag},
      bot.last_modified && {"if-modified-since", bot.last_modified}
    ]
    |> Enum.reject(&is_nil/1)
  end

  # A validator is echoed back to the server verbatim, so one that is too
  # long or carries a control character is dropped rather than stored.
  defp validators(headers) do
    %{
      etag: header_value(headers, "etag", @max_etag),
      last_modified: header_value(headers, "last-modified", @max_last_modified)
    }
  end

  defp header_value(headers, name, max) do
    value =
      case headers do
        %{} -> headers |> Map.get(name) |> List.wrap() |> List.first()
        list when is_list(list) -> List.keyfind(list, name, 0) |> then(&(&1 && elem(&1, 1)))
      end

    if is_binary(value) and value != "" and byte_size(value) <= max and
         String.printable?(value) and not String.contains?(value, ["\r", "\n"]),
       do: value,
       else: nil
  end
end
