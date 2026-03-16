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
end
