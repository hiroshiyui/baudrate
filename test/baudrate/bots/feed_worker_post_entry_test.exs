defmodule Baudrate.Bots.FeedWorkerPostEntryTest do
  @moduledoc """
  Integration coverage for `FeedWorker.post_entry/2`'s failure handling.

  `Content.create_article/3` runs an `Ecto.Multi` and surfaces failures as a
  4-tuple `{:error, op, value, changes}`. A regression where `post_entry/2`
  only matched the 2-tuple raised a `CaseClauseError`, crashing the bot and
  looping it (the entry was never recorded and the fetch cursor never moved).
  """

  use Baudrate.DataCase, async: true

  alias Baudrate.{Bots, Content}
  alias Baudrate.Bots.FeedWorker

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
        feed_url: "https://example.com/feed.xml",
        board_ids: [board.id]
      })

    %{bot: bot, board: board}
  end

  test "records the feed item without crashing when the article slug collides",
       %{bot: bot, board: board} do
    title = "Colliding Title"
    guid = "guid-collision-#{System.unique_integer([:positive])}"
    slug = FeedWorker.build_slug(title, guid)

    # Pre-create an article occupying the slug the bot entry will generate.
    {:ok, _} =
      Content.create_article(
        %{title: "Existing", body: "x", slug: slug, user_id: bot.user.id},
        [board.id]
      )

    entry = %{
      title: title,
      body: "body",
      link: "https://example.com/post/1",
      published_at: nil,
      guid: guid
    }

    # Must not raise a CaseClauseError on the 4-tuple error.
    FeedWorker.post_entry(bot, entry)

    # The item is recorded so the bot won't retry it forever.
    assert Bots.already_posted?(bot, guid, entry.link)
  end

  test "records and posts normally when there is no collision", %{bot: bot} do
    guid = "guid-ok-#{System.unique_integer([:positive])}"

    entry = %{
      title: "Fresh Entry",
      body: "hello",
      link: "https://example.com/post/2",
      published_at: nil,
      guid: guid
    }

    FeedWorker.post_entry(bot, entry)
    assert Bots.already_posted?(bot, guid, entry.link)
  end
end
