defmodule BaudrateWeb.ArticleNewLivePollTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)

    board =
      %Board{}
      |> Board.changeset(%{
        name: "Poll Board",
        slug: "poll-new-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    {:ok, conn: conn, user: user, board: board}
  end

  describe "poll form toggle" do
    test "poll section is hidden by default", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/articles/new")
      refute html =~ "poll_options"
      refute html =~ "poll_mode"

      # Toggle poll on
      html = lv |> element("button", "Add Poll") |> render_click()
      assert html =~ "poll_options"
    end

    test "toggle poll on and off", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/articles/new")

      # Enable
      html = lv |> element("button", "Add Poll") |> render_click()
      assert html =~ "poll_options"

      # Disable
      html = lv |> element("button", "Remove Poll") |> render_click()
      refute html =~ "poll_options[0]"
    end
  end

  describe "poll option management" do
    test "starts with 2 options, can add up to 4", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/articles/new")

      # Enable poll
      lv |> element("button", "Add Poll") |> render_click()

      # Should have 2 options initially
      html = render(lv)
      assert html =~ "poll_options[0]"
      assert html =~ "poll_options[1]"

      # Add third option
      lv |> element("button", "Add option") |> render_click()
      html = render(lv)
      assert html =~ "poll_options[2]"

      # Add fourth option
      lv |> element("button", "Add option") |> render_click()
      html = render(lv)
      assert html =~ "poll_options[3]"

      # Can't add more (button should be gone)
      refute html =~ "Add option"
    end

    test "can remove options down to minimum of 2", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/articles/new")

      # Enable poll and add a third option
      lv |> element("button", "Add Poll") |> render_click()
      lv |> element("button", "Add option") |> render_click()

      # Remove one option (the third one, index 2)
      lv
      |> element(~s|button[phx-click="remove_poll_option"][phx-value-index="2"]|)
      |> render_click()

      html = render(lv)
      assert html =~ "poll_options[0]"
      assert html =~ "poll_options[1]"
    end
  end

  describe "submit with poll" do
    test "creates article with poll", %{conn: conn, user: _user, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/articles/new")

      # Enable poll
      lv |> element("button", "Add Poll") |> render_click()

      # Submit the form with poll data
      lv
      |> form("#article-new-form", %{
        "article" => %{"title" => "Poll Test Article", "body" => "Has a poll"},
        "board_ids" => [to_string(board.id)],
        "poll_options" => %{"0" => "Yes", "1" => "No"},
        "poll_mode" => "single",
        "poll_expires" => ""
      })
      |> render_submit()

      # Verify article was created with poll
      article = Repo.one!(from(a in Content.Article, where: a.title == "Poll Test Article"))
      poll = Content.get_poll_for_article(article.id)
      assert poll != nil
      assert poll.mode == "single"
      assert length(poll.options) == 2
      assert poll.closes_at == nil
    end

    test "creates article with poll expiry", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/articles/new")

      lv |> element("button", "Add Poll") |> render_click()

      lv
      |> form("#article-new-form", %{
        "article" => %{"title" => "Expiry Poll", "body" => "Expiring poll"},
        "board_ids" => [to_string(board.id)],
        "poll_options" => %{"0" => "Alpha", "1" => "Beta"},
        "poll_mode" => "multiple",
        "poll_expires" => "1d"
      })
      |> render_submit()

      article = Repo.one!(from(a in Content.Article, where: a.title == "Expiry Poll"))
      poll = Content.get_poll_for_article(article.id)
      assert poll != nil
      assert poll.mode == "multiple"
      assert poll.closes_at != nil
      # Closes_at should be roughly 24 hours from now
      diff = DateTime.diff(poll.closes_at, DateTime.utc_now(), :second)
      assert diff > 86_000 and diff < 86_500
    end
  end
end
