defmodule Baudrate.Bots.BotTest do
  @moduledoc """
  Direct changeset coverage for `Baudrate.Bots.Bot`.

  The `Baudrate.Bots` context tests already exercise these changesets through
  `create_bot/1`, `update_bot/2`, and `deactivate_bot/1`, but they don't
  cover the validation surface field-by-field. These tests pin the
  individual rules so a regression in `Bot.create_changeset/2`,
  `Bot.update_changeset/2`, or `Bot.deactivate_changeset/1` surfaces
  before it reaches the context.
  """

  use Baudrate.DataCase, async: true

  alias Baudrate.Bots.Bot

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    %{}
  end

  describe "create_changeset/2" do
    test "valid with all required fields" do
      changeset =
        Bot.create_changeset(%Bot{}, %{
          user_id: 1,
          feed_url: "https://example.com/feed.xml"
        })

      assert changeset.valid?
    end

    test "requires user_id and feed_url" do
      changeset = Bot.create_changeset(%Bot{}, %{})
      errors = errors_on(changeset)
      assert errors[:user_id] == ["can't be blank"]
      assert errors[:feed_url] == ["can't be blank"]
    end

    test "rejects feed_url with no scheme" do
      changeset =
        Bot.create_changeset(%Bot{}, %{
          user_id: 1,
          feed_url: "example.com/feed.xml"
        })

      assert %{feed_url: ["must be a valid HTTP or HTTPS URL"]} = errors_on(changeset)
    end

    test "rejects file:// scheme" do
      changeset =
        Bot.create_changeset(%Bot{}, %{
          user_id: 1,
          feed_url: "file:///etc/passwd"
        })

      assert %{feed_url: ["must be a valid HTTP or HTTPS URL"]} = errors_on(changeset)
    end

    test "rejects feed_url with no host" do
      changeset =
        Bot.create_changeset(%Bot{}, %{
          user_id: 1,
          feed_url: "https://"
        })

      assert %{feed_url: ["must be a valid HTTP or HTTPS URL"]} = errors_on(changeset)
    end

    test "accepts both http and https schemes" do
      assert Bot.create_changeset(%Bot{}, %{
               user_id: 1,
               feed_url: "http://example.com/feed.xml"
             }).valid?

      assert Bot.create_changeset(%Bot{}, %{
               user_id: 1,
               feed_url: "https://example.com/feed.xml"
             }).valid?
    end

    test "rejects feed_url longer than 2048 characters" do
      long = "https://example.com/" <> String.duplicate("a", 2049)

      changeset =
        Bot.create_changeset(%Bot{}, %{
          user_id: 1,
          feed_url: long
        })

      errors = errors_on(changeset)
      assert Enum.any?(errors[:feed_url] || [], &(&1 =~ "at most"))
    end

    test "rejects fetch_interval_minutes <= 0" do
      changeset =
        Bot.create_changeset(%Bot{}, %{
          user_id: 1,
          feed_url: "https://example.com/feed.xml",
          fetch_interval_minutes: 0
        })

      assert %{fetch_interval_minutes: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "rejects fetch_interval_minutes > 1440 (24h ceiling)" do
      changeset =
        Bot.create_changeset(%Bot{}, %{
          user_id: 1,
          feed_url: "https://example.com/feed.xml",
          fetch_interval_minutes: 1441
        })

      assert %{fetch_interval_minutes: ["must be less than or equal to 1440"]} =
               errors_on(changeset)
    end

    test "accepts fetch_interval_minutes at the boundaries" do
      assert Bot.create_changeset(%Bot{}, %{
               user_id: 1,
               feed_url: "https://example.com/feed.xml",
               fetch_interval_minutes: 1
             }).valid?

      assert Bot.create_changeset(%Bot{}, %{
               user_id: 1,
               feed_url: "https://example.com/feed.xml",
               fetch_interval_minutes: 1440
             }).valid?
    end

    test "defaults to active: true" do
      bot = %Bot{}
      assert bot.active == true
    end

    test "defaults to error_count: 0 and favicon_fail_count: 0" do
      bot = %Bot{}
      assert bot.error_count == 0
      assert bot.favicon_fail_count == 0
    end
  end

  describe "update_changeset/2" do
    test "does not allow changing user_id" do
      bot = %Bot{user_id: 7, feed_url: "https://example.com/feed.xml"}

      changeset =
        Bot.update_changeset(bot, %{
          user_id: 99,
          feed_url: "https://example.com/new.xml"
        })

      # user_id is not in the cast list, so the change is silently dropped
      refute Map.has_key?(changeset.changes, :user_id)
      assert get_field(changeset, :user_id) == 7
    end

    test "still validates feed_url" do
      bot = %Bot{user_id: 1, feed_url: "https://example.com/feed.xml"}

      changeset = Bot.update_changeset(bot, %{feed_url: "not-a-url"})
      assert %{feed_url: ["must be a valid HTTP or HTTPS URL"]} = errors_on(changeset)
    end

    test "still validates fetch_interval_minutes range" do
      bot = %Bot{user_id: 1, feed_url: "https://example.com/feed.xml"}

      changeset =
        Bot.update_changeset(bot, %{
          feed_url: "https://example.com/feed.xml",
          fetch_interval_minutes: 99_999
        })

      assert %{fetch_interval_minutes: ["must be less than or equal to 1440"]} =
               errors_on(changeset)
    end

    test "requires feed_url even when other fields are present" do
      bot = %Bot{user_id: 1, feed_url: "https://example.com/feed.xml"}

      # Casting nil drops the existing value
      changeset = Bot.update_changeset(bot, %{feed_url: nil, active: false})
      assert %{feed_url: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "deactivate_changeset/1" do
    test "sets active to false" do
      bot = %Bot{user_id: 1, feed_url: "https://example.com/feed.xml", active: true}

      changeset = Bot.deactivate_changeset(bot)
      assert get_field(changeset, :active) == false
      assert changeset.changes == %{active: false}
    end

    test "no-op for an already inactive bot" do
      bot = %Bot{user_id: 1, feed_url: "https://example.com/feed.xml", active: false}

      changeset = Bot.deactivate_changeset(bot)
      assert changeset.changes == %{}
    end
  end
end
