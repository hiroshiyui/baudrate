defmodule BaudrateWeb.ArticleLivePollTest do
  use BaudrateWeb.ConnCase

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
        name: "Poll Display Board",
        slug: "poll-disp-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    {:ok, %{article: article, poll: poll}} =
      Content.create_article(
        %{
          title: "Article With Poll",
          body: "Body text",
          slug: "poll-disp-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id],
        poll: %{
          mode: "single",
          options: [
            %{text: "Option Alpha", position: 0},
            %{text: "Option Beta", position: 1}
          ]
        }
      )

    {:ok, conn: conn, user: user, board: board, article: article, poll: poll}
  end

  describe "poll display" do
    test "renders poll on article page", %{conn: conn, article: article} do
      {:ok, _lv, html} = live(conn, ~p"/articles/#{article.slug}")
      assert html =~ "Option Alpha"
      assert html =~ "Option Beta"
      assert html =~ "Poll"
    end

    test "shows vote form for logged-in user who hasn't voted", %{conn: conn, article: article} do
      {:ok, _lv, html} = live(conn, ~p"/articles/#{article.slug}")
      assert html =~ "Vote"
      assert html =~ "vote_option"
    end

    test "guest sees results without vote form", %{article: article} do
      conn = build_conn()

      {:ok, _lv, html} = live(conn, ~p"/articles/#{article.slug}")
      assert html =~ "Option Alpha"
      assert html =~ "Option Beta"
      # Guest should see results view (progress bars), not vote form
      refute html =~ "phx-submit=\"cast_vote\""
    end
  end

  describe "voting" do
    test "cast vote updates poll display", %{conn: conn, article: article, poll: poll} do
      {:ok, lv, _html} = live(conn, ~p"/articles/#{article.slug}")

      option = List.first(poll.options)

      lv
      |> form("#poll-vote-form", %{"vote_option" => to_string(option.id)})
      |> render_submit()

      html = render(lv)
      # Should show results now
      assert html =~ "100"
      assert html =~ "Change vote"
    end

    test "change vote shows form again", %{conn: conn, article: article, poll: poll} do
      {:ok, lv, _html} = live(conn, ~p"/articles/#{article.slug}")

      option = List.first(poll.options)

      lv
      |> form("#poll-vote-form", %{"vote_option" => to_string(option.id)})
      |> render_submit()

      # Click "Change vote"
      lv |> element("button", "Change vote") |> render_click()
      html = render(lv)
      assert html =~ "phx-submit=\"cast_vote\""
    end
  end

  describe "closed poll" do
    test "shows results for closed poll", %{conn: conn, user: user, board: board} do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      # Create article without poll first, then insert poll with past date directly
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Closed Poll Article",
            body: "Closed",
            slug: "closed-poll-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      # Insert poll directly, bypassing future validation
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      poll =
        Repo.insert!(%Content.Poll{
          article_id: article.id,
          mode: "single",
          closes_at: past,
          voters_count: 0,
          inserted_at: now,
          updated_at: now
        })

      Repo.insert!(%Content.PollOption{
        poll_id: poll.id,
        text: "Past A",
        position: 0,
        votes_count: 0,
        inserted_at: now,
        updated_at: now
      })

      Repo.insert!(%Content.PollOption{
        poll_id: poll.id,
        text: "Past B",
        position: 1,
        votes_count: 0,
        inserted_at: now,
        updated_at: now
      })

      {:ok, _lv, html} = live(conn, ~p"/articles/#{article.slug}")
      assert html =~ "Closed"
      refute html =~ "phx-submit=\"cast_vote\""
    end
  end

  describe "article without poll" do
    test "does not render poll section", %{conn: conn, user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "No Poll",
            body: "Just an article",
            slug: "no-poll-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, _lv, html} = live(conn, ~p"/articles/#{article.slug}")
      refute html =~ "article-poll"
    end
  end
end
