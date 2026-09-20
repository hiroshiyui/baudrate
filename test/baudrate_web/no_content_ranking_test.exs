defmodule BaudrateWeb.NoContentRankingTest do
  @moduledoc """
  Acceptance gate for [ADR 0054](../../doc/adr/0054-attention-follows-the-board-not-a-ranking.md):
  attention follows the board, and nothing is ranked by engagement.

  This covers the falsifiable part of that record. It cannot decide whether
  some future surface *is* a ranking — that judgement is listed as ungated in
  `doc/baudrate-spec.md`. What it can do is fail the build for the three
  shapes the decision was actually written against, all of which look like
  improvements from inside a pull request:

    * a `/popular`, `/trending`, `/hot` or `/recent` route appearing;
    * the home page growing a list of articles from across the boards;
    * the board list being sorted by activity instead of the admin's order.
  """

  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  # The last two are ADR 0055's, and are here for different reasons from the
  # rest: `/unanswered` ranks nothing, but a cross-board list of articles is a
  # river whatever orders it; a `/tags` index ranks topics by use, and the
  # alphabetical alternative is a sitemap. `/tags/:tag` is a different route
  # and stays — the reader named the tag.
  @ranking_paths ~w(/popular /trending /hot /recent /top /unanswered /tags)

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  defp record_for(path) when path in ["/unanswered", "/tags"], do: "ADR 0055"
  defp record_for(_path), do: "ADR 0054"

  # Letters only. The post-count probe below looks for a bare "3" inside a
  # rendered card, and a numeric slug suffix would answer it.
  defp alpha_suffix, do: for(_ <- 1..8, into: "", do: <<Enum.random(?a..?z)>>)

  defp public_board(name, attrs \\ %{}) do
    %Board{}
    |> Board.changeset(
      Map.merge(
        %{
          name: name,
          slug:
            "#{name |> String.downcase() |> String.replace(~r/[^a-z]/, "")}-#{alpha_suffix()}",
          min_role_to_view: "guest"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "no ranking or cross-board river route is mounted" do
    mounted =
      BaudrateWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(& &1.path)

    for path <- @ranking_paths do
      refute path in mounted,
             """
             #{path} is mounted, which #{record_for(path)} decided against.

             A popularity list is a feedback loop — what it surfaces gets read,
             which keeps it surfaced — and engagement cannot tell an argument
             from a conversation. A river ranks nothing and is refused anyway:
             it takes articles out of the board they were written in, and
             `/unanswered` is that case wearing the face of kindness.

             If this is a deliberate reversal it needs a superseding ADR, not
             a route.
             """
    end
  end

  test "the home page lists boards, not the articles inside them", %{conn: conn} do
    board = public_board("Open Board")
    user = setup_user("user")

    {:ok, _} =
      Content.create_article(
        %{
          title: "An Article Nobody Asked To See Here",
          body: "body",
          slug: "ranking-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    {:ok, _lv, html} = live(conn, "/")

    assert html =~ "Open Board"

    refute html =~ "An Article Nobody Asked To See Here",
           "the home page rendered an article title. ADR 0054: the board is " <>
             "the unit, and there is no river of posts across boards."
  end

  test "board order comes from position, not from activity", %{conn: conn} do
    # `second` is created later and gets the only article, so any
    # activity-based ordering would put it first.
    first = public_board("Alpha Board", %{position: 1})
    second = public_board("Beta Board", %{position: 2})
    user = setup_user("user")

    {:ok, _} =
      Content.create_article(
        %{
          title: "Busy",
          body: "body",
          slug: "busy-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [second.id]
      )

    {:ok, _lv, html} = live(conn, "/")

    # Both must render, or the comparison below is vacuous: `:nomatch` is an
    # atom, and an atom sorts below every tuple in Erlang term order.
    assert {first_at, _} = :binary.match(html, first.name)
    assert {second_at, _} = :binary.match(html, second.name)

    assert first_at < second_at,
           "the busier board was listed first. ADR 0054: board order is " <>
             "editorial (`Board.position`), because sorting by activity is a " <>
             "ranking in the place it is least visible as one."
  end

  test "a board card carries no post count", %{conn: conn} do
    board = public_board("Counted Board")
    user = setup_user("user")

    for n <- 1..3 do
      {:ok, _} =
        Content.create_article(
          %{
            title: "Post #{n}",
            body: "body",
            slug: "counted-#{n}-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )
    end

    {:ok, _lv, html} = live(conn, "/")

    card =
      html
      |> String.split(~s(id="board-#{board.slug}"))
      |> Enum.at(1)
      |> String.split("</a>")
      |> List.first()

    assert card =~ "Counted Board",
           "could not isolate the board card; the probe below would pass on " <>
             "an empty string."

    refute card =~ ~r/\b3\b/,
           "the board card rendered what looks like a post count. ADR 0054: " <>
             "a count is a scoreboard between boards, and it delivers a " <>
             "verdict on the quiet ones before a visitor has opened either."
  end
end
