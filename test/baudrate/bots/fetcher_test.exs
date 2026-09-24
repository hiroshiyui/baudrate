defmodule Baudrate.Bots.FetcherTest do
  @moduledoc """
  Phase 7D: one fetch of a bot's feed — the conditional request, the
  include/exclude filters, the first-fetch limit, the dry run, and switching
  a bot off after `Bot.max_failures/0` failures with a notice to the admins.
  """

  use Baudrate.DataCase, async: true

  import Ecto.Query

  alias Baudrate.{Bots, Content}
  alias Baudrate.Bots.{Bot, BotSyndicationItem, Fetcher}
  alias Baudrate.Content.Article
  alias Baudrate.Federation.HTTPClient
  alias Baudrate.Notification.Notification

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    board =
      %Content.Board{}
      |> Content.Board.changeset(%{
        name: "Bot Board",
        slug: "bot-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    {:ok, bot} =
      Bots.create_bot(%{
        username: "bot_#{System.unique_integer([:positive])}",
        feed_url: "https://feed.example/feed.xml",
        board_ids: [board.id]
      })

    %{bot: bot, board: board}
  end

  # An RSS document, newest entry first, one day apart.
  defp rss(items) do
    body =
      items
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{guid, title, text}, i} ->
        date =
          DateTime.utc_now()
          |> DateTime.add(-(i + 1) * 86_400, :second)
          |> Calendar.strftime("%a, %d %b %Y %H:%M:%S +0000")

        """
        <item>
          <guid>#{guid}</guid>
          <title>#{title}</title>
          <link>https://feed.example/#{guid}</link>
          <description>#{text}</description>
          <pubDate>#{date}</pubDate>
        </item>
        """
      end)

    """
    <?xml version="1.0"?>
    <rss version="2.0"><channel><title>Feed</title><link>https://feed.example/</link>
    #{body}
    </channel></rss>
    """
  end

  defp items(n), do: for(i <- 1..n, do: {"g#{i}", "Entry #{i}", "Text #{i}"})

  defp serve(xml, headers \\ []) do
    test_pid = self()

    Req.Test.stub(HTTPClient, fn conn ->
      send(test_pid, {:request_headers, conn.req_headers})

      headers
      |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
      |> Plug.Conn.send_resp(200, xml)
    end)
  end

  defp posted_titles(bot) do
    Repo.all(
      from a in Article, where: a.user_id == ^bot.user.id, order_by: a.title, select: a.title
    )
  end

  defp fetched(bot), do: bot |> Map.put(:last_fetched_at, DateTime.utc_now())

  defp reload(bot), do: Bots.get_bot!(bot.id)

  describe "the first fetch" do
    test "posts only the newest first_fetch_limit entries and records the rest",
         %{bot: bot} do
      {:ok, bot} = Bots.update_bot(bot, %{first_fetch_limit: 2})
      serve(rss(items(5)))

      assert :ok = Fetcher.run(reload(bot))

      assert posted_titles(bot) == ["Entry 1", "Entry 2"]

      ledger =
        Repo.all(from i in BotSyndicationItem, where: i.bot_id == ^bot.id, select: i.guid)

      assert Enum.sort(ledger) == ~w(g1 g2 g3 g4 g5)

      # The backlog stays skipped on the next fetch.
      serve(rss(items(5)))
      assert :ok = Fetcher.run(reload(bot))
      assert posted_titles(bot) == ["Entry 1", "Entry 2"]
    end

    test "a limit of 0 posts nothing and records everything", %{bot: bot} do
      {:ok, bot} = Bots.update_bot(bot, %{first_fetch_limit: 0})
      serve(rss(items(3)))

      Fetcher.run(reload(bot))

      assert posted_titles(bot) == []

      assert Repo.aggregate(from(i in BotSyndicationItem, where: i.bot_id == ^bot.id), :count) ==
               3
    end

    test "a later fetch posts every new entry, whatever the limit", %{bot: bot} do
      {:ok, bot} = Bots.update_bot(bot, %{first_fetch_limit: 1})
      bot = fetched(reload(bot))

      assert Fetcher.plan(bot, parse(rss(items(3)))) |> Enum.map(&elem(&1, 1)) ==
               [:post, :post, :post]
    end

    test "a new feed URL starts over as a first fetch", %{bot: bot} do
      {:ok, _} = Bots.mark_fetch_success(bot, nil, %{etag: "\"v1\"", last_modified: nil})

      {:ok, bot} = Bots.update_bot(reload(bot), %{feed_url: "https://other.example/rss"})

      assert bot.last_fetched_at == nil
      assert bot.etag == nil
      assert bot.next_fetch_at == nil
    end
  end

  describe "filters" do
    test "exclude patterns skip an entry; include patterns require a match", %{bot: bot} do
      {:ok, bot} =
        Bots.update_bot(bot, %{
          "include_text" => "elixir\n*rust*",
          "exclude_text" => "sponsored"
        })

      entries =
        parse(
          rss([
            {"a", "Elixir 2.0 released", "news"},
            {"b", "Trusted builds", "about builds"},
            {"c", "Elixir meetup", "a Sponsored post"},
            {"d", "Gardening", "tomatoes"}
          ])
        )

      assert bot |> fetched() |> Fetcher.plan(entries) |> Enum.map(&elem(&1, 1)) ==
               [:post, :post, :excluded, :not_included]
    end

    test "an entry already posted is :seen and not recorded again", %{bot: bot} do
      Bots.record_syndication_item(bot, "a", nil)
      entries = parse(rss([{"a", "One", "x"}]))

      assert [{_, :seen}] = Fetcher.plan(fetched(bot), entries)
    end

    test "a filtered entry is recorded, so changing the filters never posts it later",
         %{bot: bot} do
      {:ok, bot} =
        Bots.update_bot(bot, %{"exclude_text" => "gardening", "first_fetch_limit" => 5})

      serve(rss([{"a", "Gardening", "x"}, {"b", "Cooking", "y"}]))
      Fetcher.run(reload(bot))

      {:ok, bot} = Bots.update_bot(reload(bot), %{"exclude_text" => ""})
      assert reload(bot).exclude_patterns == []

      serve(rss([{"a", "Gardening", "x"}, {"b", "Cooking", "y"}]))
      Fetcher.run(reload(bot))

      assert posted_titles(bot) == ["Cooking"]
    end

    test "patterns are validated with the content filters' rule", %{bot: bot} do
      assert {:error, cs} = Bots.update_bot(bot, %{"include_text" => "ok\n!!!"})

      assert {"\"%{pattern}\" has no letters or numbers", [pattern: "!!!"]} =
               cs.errors[:include_text]

      assert {:error, cs} = Bots.update_bot(bot, %{"exclude_text" => "a*b c"})
      assert {_, [pattern: "a*b c"]} = cs.errors[:exclude_text]

      too_many = Enum.map_join(1..(Bot.max_patterns() + 1), "\n", &"word#{&1}")
      assert {:error, cs} = Bots.update_bot(bot, %{"include_text" => too_many})
      assert {"may hold at most %{max} patterns", _} = cs.errors[:include_text]
    end

    test "a line with * is a substring pattern, any other a word pattern" do
      assert Bot.parse_patterns("Elixir\n\n  *RUST*  \nelixir") == [
               %{"kind" => "word", "pattern" => "elixir"},
               %{"kind" => "substring", "pattern" => "*rust*"}
             ]

      assert Bot.patterns_text(Bot.parse_patterns("a\n*b*")) == "a\n*b*"
    end
  end

  describe "conditional GET" do
    test "stores the validators and sends them back; a 304 is a quiet success",
         %{bot: bot} do
      serve(rss(items(1)), [
        {"etag", "\"abc\""},
        {"last-modified", "Tue, 01 Sep 2026 00:00:00 GMT"}
      ])

      Fetcher.run(reload(bot))

      assert_received {:request_headers, first}
      refute List.keymember?(first, "if-none-match", 0)
      assert {"accept", accept} = List.keyfind(first, "accept", 0)
      assert accept =~ "application/rss+xml"
      assert accept =~ "application/atom+xml"

      bot = reload(bot)
      assert bot.etag == "\"abc\""
      assert bot.last_modified == "Tue, 01 Sep 2026 00:00:00 GMT"

      test_pid = self()

      Req.Test.stub(HTTPClient, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 304, "")
      end)

      Repo.update_all(from(b in Bot, where: b.id == ^bot.id), set: [error_count: 2])

      assert :ok = Fetcher.run(reload(bot))

      assert_received {:request_headers, second}
      assert {"if-none-match", "\"abc\""} = List.keyfind(second, "if-none-match", 0)
      assert {"if-modified-since", _} = List.keyfind(second, "if-modified-since", 0)

      bot = reload(bot)
      assert bot.error_count == 0
      assert bot.etag == "\"abc\""
    end

    test "an overlong validator is not stored", %{bot: bot} do
      serve(rss(items(1)), [{"etag", String.duplicate("x", 600)}])
      Fetcher.run(reload(bot))
      assert reload(bot).etag == nil
    end

    test "a 304 to an unconditional request is still an error" do
      Req.Test.stub(HTTPClient, fn conn -> Plug.Conn.send_resp(conn, 304, "") end)

      assert {:error, {:http_error, 304, ""}} =
               HTTPClient.get_html("https://feed.example/x")
    end
  end

  describe "preview/1 (the dry run)" do
    test "reports each decision and changes nothing", %{bot: bot} do
      {:ok, bot} = Bots.update_bot(bot, %{"first_fetch_limit" => 1, "exclude_text" => "entry 3"})
      serve(rss(items(3)), [{"etag", "\"v\""}])

      assert {:ok, rows} = Bots.preview(reload(bot))
      assert Enum.map(rows, &elem(&1, 1)) == [:post, :backlog, :excluded]

      assert posted_titles(bot) == []

      assert Repo.aggregate(from(i in BotSyndicationItem, where: i.bot_id == ^bot.id), :count) ==
               0

      after_bot = reload(bot)
      assert after_bot.etag == nil
      assert after_bot.last_fetched_at == nil
    end

    test "is never conditional", %{bot: bot} do
      {:ok, _} = Bots.mark_fetch_success(bot, nil, %{etag: "\"v1\"", last_modified: nil})
      serve(rss(items(1)))

      assert {:ok, [_]} = Bots.preview(reload(bot))
      assert_received {:request_headers, headers}
      refute List.keymember?(headers, "if-none-match", 0)
    end

    test "returns the fetch error", %{bot: bot} do
      Req.Test.stub(HTTPClient, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
      assert {:error, {:http_error, 500, _}} = Bots.preview(bot)
      assert reload(bot).error_count == 0
    end
  end

  describe "failures" do
    setup do
      admin = BaudrateWeb.ConnCase.setup_user("admin")
      %{admin: admin}
    end

    test "a bot is switched off at max_failures and every admin is told once",
         %{bot: bot, admin: admin} do
      Repo.update_all(from(b in Bot, where: b.id == ^bot.id),
        set: [error_count: Bot.max_failures() - 2]
      )

      {:ok, bot} = Bots.mark_fetch_error(reload(bot), "timeout")
      assert bot.active
      refute Repo.exists?(from n in Notification, where: n.type == "bot_disabled")

      {:ok, bot} = Bots.mark_fetch_error(reload(bot), "timeout")
      refute bot.active
      assert bot.error_count == Bot.max_failures()

      assert [notice] =
               Repo.all(
                 from n in Notification,
                   where: n.type == "bot_disabled" and n.user_id == ^admin.id
               )

      assert notice.data["bot_id"] == bot.id
      assert notice.data["username"] == bot.user.username
      assert "bot_disabled" in Notification.always_delivered_types()

      # An inactive bot is never fetched, but a failure recorded for one
      # must not notify twice.
      {:ok, _} = Bots.mark_fetch_error(reload(bot), "timeout")

      assert Repo.aggregate(
               from(n in Notification,
                 where: n.type == "bot_disabled" and n.user_id == ^admin.id
               ),
               :count
             ) == 1
    end

    test "switching the bot back on clears its error count", %{bot: bot} do
      Repo.update_all(from(b in Bot, where: b.id == ^bot.id),
        set: [active: false, error_count: Bot.max_failures()]
      )

      {:ok, bot} = Bots.update_bot(reload(bot), %{active: true})
      assert bot.error_count == 0
      assert bot.next_fetch_at == nil
    end

    test "a failed run counts as an error", %{bot: bot} do
      Req.Test.stub(HTTPClient, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      Fetcher.run(reload(bot))
      assert reload(bot).error_count == 1
    end
  end

  describe "fetch_now/1 and post_counts/0" do
    test "fetch_now schedules an active bot and leaves its errors alone", %{bot: bot} do
      Repo.update_all(from(b in Bot, where: b.id == ^bot.id),
        set: [error_count: 3, next_fetch_at: DateTime.add(DateTime.utc_now(), 3600, :second)]
      )

      assert :ok = Bots.fetch_now(reload(bot))
      bot = reload(bot)
      assert bot.error_count == 3
      assert DateTime.compare(bot.next_fetch_at, DateTime.utc_now()) != :gt
    end

    test "fetch_now refuses an inactive bot", %{bot: bot} do
      {:ok, bot} = Bots.update_bot(bot, %{active: false})
      assert {:error, :inactive} = Bots.fetch_now(bot)
    end

    test "post_counts counts articles not withdrawn", %{bot: bot} do
      {:ok, bot} = Bots.update_bot(bot, %{first_fetch_limit: 3})
      serve(rss(items(3)))
      Fetcher.run(reload(bot))

      [a | _] = Repo.all(from a in Article, where: a.user_id == ^bot.user.id)

      Repo.update_all(from(x in Article, where: x.id == ^a.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      assert Bots.post_counts()[bot.id] == 2
    end
  end

  defp parse(xml) do
    {:ok, entries} = Baudrate.Bots.SyndicationFeedParser.parse(xml)
    entries
  end
end
