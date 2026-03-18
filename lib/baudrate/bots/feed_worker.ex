defmodule Baudrate.Bots.FeedWorker do
  @moduledoc """
  GenServer that polls for due bots and fetches their RSS/Atom feeds.

  Follows the `Baudrate.Federation.DeliveryWorker` pattern:
  - Polls every 60 seconds with ±10% jitter (configurable via `bots_poll_interval`)
  - Processes up to 5 bots concurrently (configurable via `bots_max_concurrency`)
  - Per-bot: optionally refresh favicon, fetch feed, create articles, record items
  - Graceful shutdown: sets `shutting_down` flag, skips new polls
  """

  use GenServer

  require Logger

  alias Baudrate.Bots
  alias Baudrate.Bots.{FaviconFetcher, FeedParser}
  alias Baudrate.Content
  alias Baudrate.Federation.HTTPClient

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    schedule_poll()
    {:ok, %{shutting_down: false}}
  end

  @impl true
  def handle_info(:poll, %{shutting_down: true} = state) do
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    process_due_bots()
    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("bots.feed_worker: shutting down (reason: #{inspect(reason)})")
    :ok
  end

  defp schedule_poll do
    config = Application.get_env(:baudrate, Baudrate.Bots, [])
    interval = config[:bots_poll_interval] || 60_000
    jitter = :rand.uniform(div(interval, 5)) - div(interval, 10)
    Process.send_after(self(), :poll, interval + jitter)
  end

  defp process_due_bots do
    bots = Bots.list_due_bots()

    if bots != [] do
      Logger.info("bots.feed_worker: processing #{length(bots)} due bots")
    end

    config = Application.get_env(:baudrate, Baudrate.Bots, [])
    max_concurrency = config[:bots_max_concurrency] || 5

    Baudrate.Federation.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      bots,
      fn bot -> process_bot(bot) end,
      max_concurrency: max_concurrency,
      timeout: 120_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()
  end

  defp process_bot(bot) do
    Logger.info("bots.feed_worker: fetching feed for bot #{bot.id} (#{bot.feed_url})")

    # Best-effort avatar refresh
    if Bots.avatar_needs_refresh?(bot) do
      Task.Supervisor.start_child(
        Baudrate.Federation.TaskSupervisor,
        fn -> FaviconFetcher.fetch_and_set(bot) end
      )
    end

    case fetch_and_parse_feed(bot) do
      {:ok, entries} ->
        post_entries(bot, entries)
        Bots.mark_fetch_success(bot)

      {:error, reason} ->
        error_msg = inspect(reason)
        Logger.warning("bots.feed_worker: fetch failed for bot #{bot.id}: #{error_msg}")
        Bots.mark_fetch_error(bot, error_msg)
    end
  end

  defp fetch_and_parse_feed(bot) do
    case HTTPClient.validate_url(bot.feed_url) do
      :ok ->
        case HTTPClient.get_html(bot.feed_url, max_size: 5 * 1024 * 1024) do
          {:ok, %{body: body}} ->
            FeedParser.parse(body)

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp post_entries(bot, entries) do
    Enum.each(entries, fn entry ->
      if not Bots.already_posted?(bot, entry.guid, entry.link) do
        post_entry(bot, entry)
      end
    end)
  end

  defp post_entry(bot, entry) do
    slug = build_slug(entry.title, entry.guid)

    attrs = %{
      title: entry.title,
      body: entry.body || "",
      slug: slug,
      user_id: bot.user.id,
      url: entry.link,
      published_at: entry.published_at,
      visibility: "public",
      forwardable: true
    }

    case Content.create_article(attrs, bot.board_ids) do
      {:ok, %{article: article}} ->
        Bots.record_feed_item(bot, entry.guid, article.id)
        Logger.debug("bots.feed_worker: posted article #{article.id} for bot #{bot.id}")

      {:error, reason} ->
        Logger.warning(
          "bots.feed_worker: failed to post entry #{inspect(entry.guid)} for bot #{bot.id}: #{inspect(reason)}"
        )

        # Still record the item so we don't retry forever on permanent failures
        Bots.record_feed_item(bot, entry.guid, nil)
    end
  end

  defp build_slug(title, guid) do
    # Slugify title: lowercase, replace non-alphanumeric with hyphens
    base =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    # Hash suffix from guid for uniqueness
    hash =
      :crypto.hash(:sha256, guid)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 8)

    slug = if base == "", do: hash, else: "#{base}-#{hash}"

    # Ensure slug matches format requirement
    slug
    |> String.replace(~r/[^a-z0-9-]/, "")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
