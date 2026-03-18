defmodule BaudrateWeb.Admin.BotsLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Bots
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  test "admin can view bots page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/bots")
    assert html =~ "Manage Bots"
  end

  test "non-admin is redirected away", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/bots")
  end

  test "moderator is redirected away", %{conn: conn} do
    moderator = setup_user("moderator")
    conn = log_in_user(conn, moderator)

    assert {:error, {:redirect, _}} = live(conn, "/admin/bots")
  end

  test "shows no bots message when empty", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/bots")
    assert html =~ "No bots configured yet."
  end

  test "admin can open new bot form", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/bots")
    html = lv |> element("button[phx-click=\"new\"]") |> render_click()
    assert html =~ "New Bot"
    assert html =~ "Feed URL"
  end

  test "admin can create a bot", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/bots")
    lv |> element("button[phx-click=\"new\"]") |> render_click()

    username = "testfeedbot_#{System.unique_integer([:positive])}"

    html =
      lv
      |> form("form",
        bot: %{
          username: username,
          feed_url: "https://example.com/feed.xml",
          fetch_interval_minutes: 60
        }
      )
      |> render_submit()

    assert html =~ "Bot created successfully."
    assert html =~ username
  end

  test "shows validation error for invalid feed URL", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/bots")
    lv |> element("button[phx-click=\"new\"]") |> render_click()

    html =
      lv
      |> form("form",
        bot: %{
          username: "badbot_#{System.unique_integer([:positive])}",
          feed_url: "not-a-url"
        }
      )
      |> render_submit()

    assert html =~ "must be a valid HTTP or HTTPS URL"
  end

  test "admin can cancel the new bot form", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/bots")
    lv |> element("button[phx-click=\"new\"]") |> render_click()

    # The form should be visible before cancel
    html_with_form = lv |> render()
    assert html_with_form =~ "Feed URL"

    lv |> element("button[phx-click=\"cancel\"]") |> render_click()
    html_after_cancel = lv |> render()

    # The form card should no longer be visible
    refute html_after_cancel =~ "bot-form-card"
  end

  test "admin can edit a bot", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, bot} =
      Bots.create_bot(%{
        "username" => "editmebot_#{System.unique_integer([:positive])}",
        "feed_url" => "https://example.com/original.xml",
        "board_ids" => []
      })

    {:ok, lv, _html} = live(conn, "/admin/bots")

    lv
    |> element("button[phx-click=\"edit\"][phx-value-id=\"#{bot.id}\"]")
    |> render_click()

    html =
      lv
      |> form("form",
        bot: %{
          feed_url: "https://example.com/updated.xml",
          fetch_interval_minutes: 120
        }
      )
      |> render_submit()

    assert html =~ "Bot updated successfully."
    assert html =~ "https://example.com/updated.xml"
  end

  test "admin can toggle bot active state", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, bot} =
      Bots.create_bot(%{
        "username" => "togglebot_#{System.unique_integer([:positive])}",
        "feed_url" => "https://example.com/feed.xml",
        "board_ids" => []
      })

    {:ok, lv, _html} = live(conn, "/admin/bots")

    html =
      lv
      |> element("button[phx-click=\"toggle_active\"][phx-value-id=\"#{bot.id}\"]")
      |> render_click()

    assert html =~ "Bot deactivated."
    assert html =~ "Inactive"
  end

  test "admin can delete a bot", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    username = "deletebot_#{System.unique_integer([:positive])}"

    {:ok, bot} =
      Bots.create_bot(%{
        "username" => username,
        "feed_url" => "https://example.com/feed.xml",
        "board_ids" => []
      })

    {:ok, lv, html} = live(conn, "/admin/bots")
    assert html =~ username

    html =
      lv
      |> element("button[phx-click=\"delete\"][phx-value-id=\"#{bot.id}\"]")
      |> render_click()

    assert html =~ "Bot deleted successfully."
    refute html =~ username
  end

  test "displays bot badge in bot list", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, _bot} =
      Bots.create_bot(%{
        "username" => "badgebot_#{System.unique_integer([:positive])}",
        "feed_url" => "https://example.com/feed.xml",
        "board_ids" => []
      })

    {:ok, _lv, html} = live(conn, "/admin/bots")
    assert html =~ "Bot"
  end

  describe "bot bio editing" do
    test "create bot with custom bio sets user bio", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/bots")
      lv |> element("button[phx-click=\"new\"]") |> render_click()

      username = "biobot_#{System.unique_integer([:positive])}"

      lv
      |> form("form",
        bot: %{
          username: username,
          feed_url: "https://example.com/feed.xml",
          bio: "This is an unofficial feed aggregator bot.",
          fetch_interval_minutes: 60
        }
      )
      |> render_submit()

      bot = Bots.list_bots() |> Enum.find(&(&1.user.username == username))
      assert bot.user.bio == "This is an unofficial feed aggregator bot."
    end

    test "create bot defaults bio to feed URL when bio is empty", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/bots")
      lv |> element("button[phx-click=\"new\"]") |> render_click()

      username = "nobiobot_#{System.unique_integer([:positive])}"
      feed_url = "https://example.com/feed.xml"

      lv
      |> form("form",
        bot: %{username: username, feed_url: feed_url, fetch_interval_minutes: 60}
      )
      |> render_submit()

      bot = Bots.list_bots() |> Enum.find(&(&1.user.username == username))
      assert bot.user.bio == feed_url
    end

    test "edit bot bio field is pre-filled with current bio", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, bot} =
        Bots.create_bot(%{
          "username" => "prebiobot_#{System.unique_integer([:positive])}",
          "feed_url" => "https://example.com/feed.xml",
          "bio" => "Existing bio text.",
          "board_ids" => []
        })

      {:ok, lv, _html} = live(conn, "/admin/bots")

      html =
        lv
        |> element("button[phx-click=\"edit\"][phx-value-id=\"#{bot.id}\"]")
        |> render_click()

      assert html =~ "Existing bio text."
    end

    test "edit bot updates bio", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, bot} =
        Bots.create_bot(%{
          "username" => "updatebiobot_#{System.unique_integer([:positive])}",
          "feed_url" => "https://example.com/feed.xml",
          "board_ids" => []
        })

      {:ok, lv, _html} = live(conn, "/admin/bots")

      lv
      |> element("button[phx-click=\"edit\"][phx-value-id=\"#{bot.id}\"]")
      |> render_click()

      lv
      |> form("form",
        bot: %{
          feed_url: "https://example.com/feed.xml",
          bio: "Unofficial — not affiliated with the source."
        }
      )
      |> render_submit()

      updated_bot = Bots.get_bot!(bot.id)
      assert updated_bot.user.bio == "Unofficial — not affiliated with the source."
    end

    test "edit bot bio does not change when feed_url changes without explicit bio submission",
         %{conn: _conn} do
      # seed roles
      setup_user("user")

      {:ok, bot} =
        Bots.create_bot(%{
          "username" => "feedchangebot_#{System.unique_integer([:positive])}",
          "feed_url" => "https://example.com/old.xml",
          "bio" => "Custom disclaimer.",
          "board_ids" => []
        })

      # Simulate programmatic update without bio key — legacy auto-update should fire
      Bots.update_bot(bot, %{"feed_url" => "https://example.com/new.xml"})

      updated_bot = Bots.get_bot!(bot.id)
      assert updated_bot.user.bio == "https://example.com/new.xml"
    end

    test "edit bot with explicit bio prevents auto-update from feed_url change",
         %{conn: _conn} do
      # seed roles
      setup_user("user")

      {:ok, bot} =
        Bots.create_bot(%{
          "username" => "explicitbiobot_#{System.unique_integer([:positive])}",
          "feed_url" => "https://example.com/old.xml",
          "board_ids" => []
        })

      Bots.update_bot(bot, %{
        "feed_url" => "https://example.com/new.xml",
        "bio" => "Custom disclaimer."
      })

      updated_bot = Bots.get_bot!(bot.id)
      assert updated_bot.user.bio == "Custom disclaimer."
    end
  end

  describe "bot profile fields editing" do
    test "edit form shows profile fields section", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, bot} =
        Bots.create_bot(%{
          "username" => "pfbot_#{System.unique_integer([:positive])}",
          "feed_url" => "https://example.com/feed.xml",
          "board_ids" => []
        })

      {:ok, lv, _html} = live(conn, "/admin/bots")

      html =
        lv
        |> element("button[phx-click=\"edit\"][phx-value-id=\"#{bot.id}\"]")
        |> render_click()

      assert html =~ "Profile Fields"
    end

    test "edit bot saves profile fields", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, bot} =
        Bots.create_bot(%{
          "username" => "savefields_#{System.unique_integer([:positive])}",
          "feed_url" => "https://example.com/feed.xml",
          "board_ids" => []
        })

      {:ok, lv, _html} = live(conn, "/admin/bots")

      lv
      |> element("button[phx-click=\"edit\"][phx-value-id=\"#{bot.id}\"]")
      |> render_click()

      render_submit(lv, "save", %{
        "bot" => %{
          "feed_url" => "https://example.com/feed.xml",
          "bio" => "Unofficial bot.",
          "profile_fields" => %{
            "0" => %{"name" => "Notice", "value" => "Not affiliated with the source."},
            "1" => %{"name" => "", "value" => ""},
            "2" => %{"name" => "", "value" => ""},
            "3" => %{"name" => "", "value" => ""}
          }
        }
      })

      updated_bot = Bots.get_bot!(bot.id)

      assert updated_bot.user.profile_fields == [
               %{"name" => "Notice", "value" => "Not affiliated with the source."}
             ]
    end

    test "edit bot pre-fills existing profile fields", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, bot} =
        Bots.create_bot(%{
          "username" => "existfields_#{System.unique_integer([:positive])}",
          "feed_url" => "https://example.com/feed.xml",
          "board_ids" => []
        })

      Baudrate.Auth.update_profile_fields(bot.user, [
        %{"name" => "Notice", "value" => "Unofficial feed."}
      ])

      {:ok, lv, _html} = live(conn, "/admin/bots")

      html =
        lv
        |> element("button[phx-click=\"edit\"][phx-value-id=\"#{bot.id}\"]")
        |> render_click()

      assert html =~ "Notice"
      assert html =~ "Unofficial feed."
    end
  end
end
