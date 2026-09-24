defmodule Baudrate.Bots.SyndicationFeedWorker do
  @moduledoc """
  GenServer that polls for due bots and fetches their RSS/Atom feeds.

  Follows the `Baudrate.Federation.DeliveryWorker` pattern:
  - Polls every 60 seconds with ±10% jitter (configurable via `bots_poll_interval`)
  - Processes up to 5 bots concurrently (configurable via `bots_max_concurrency`)
  - Per-bot: optionally refresh favicon, then `Baudrate.Bots.Fetcher.run/1`
    (conditional fetch, filters, the first-fetch limit, posting, recording)
  - Graceful shutdown: sets `shutting_down` flag, skips new polls
  """

  use GenServer

  require Logger

  alias Baudrate.Bots
  alias Baudrate.Bots.{FaviconFetcher, Fetcher}
  alias Baudrate.Content

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
    Baudrate.Health.Heartbeat.beat(:syndication_feed_worker)
    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("bots.syndication_feed_worker: shutting down (reason: #{inspect(reason)})")
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
      Logger.info("bots.syndication_feed_worker: processing #{length(bots)} due bots")
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
    Logger.info("bots.syndication_feed_worker: fetching feed for bot #{bot.id} (#{bot.feed_url})")

    # Best-effort avatar refresh
    if Bots.avatar_needs_refresh?(bot) do
      Task.Supervisor.start_child(
        Baudrate.Federation.TaskSupervisor,
        fn -> FaviconFetcher.fetch_and_set(bot) end
      )
    end

    Fetcher.run(bot)
  end

  @doc false
  # Public for unit testing — see test/baudrate/bots/syndication_feed_worker_test.exs.
  # Creates an article for a single feed entry and records the timeline item.
  # A failed insert (e.g. a slug `unique_constraint` collision) must record
  # the item and return normally rather than crash the bot's poll loop.
  def post_entry(bot, entry) do
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

    case Content.create_article(attrs, bot.board_ids, trusted: true) do
      {:ok, %{article: article}} ->
        # Feed bodies are the highest-volume source of remote images; warm the
        # media cache so the first reader does not wait on the publisher's CDN.
        Baudrate.Media.Warmer.warm_html(entry.body)
        Bots.record_syndication_item(bot, entry.guid, article.id)

        Logger.debug(
          "bots.syndication_feed_worker: posted article #{article.id} for bot #{bot.id}"
        )

      error ->
        # `create_article/3` surfaces failures from its `Ecto.Multi` as a 4-tuple
        # `{:error, failed_op, value, changes}` (e.g. a slug `unique_constraint`
        # collision). Match any error shape so a failed insert records the item
        # and moves on instead of crashing the bot with a `CaseClauseError` and
        # looping it forever.
        reason =
          case error do
            {:error, _op, value, _changes} -> value
            {:error, value} -> value
            other -> other
          end

        Logger.warning(
          "bots.syndication_feed_worker: failed to post entry #{inspect(entry.guid)} for bot #{bot.id}: #{inspect(reason)}"
        )

        # Still record the item so we don't retry forever on permanent failures
        Bots.record_syndication_item(bot, entry.guid, nil)
    end
  end

  @doc false
  # Public for unit testing — see test/baudrate/bots/syndication_feed_worker_test.exs.
  # Builds a deterministic, URL-safe slug from a feed entry's title and GUID:
  # the title is lowercased and stripped to `[a-z0-9-]`, then suffixed with
  # an 8-char SHA-256 hash of the GUID for uniqueness.
  def build_slug(title, guid) do
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
