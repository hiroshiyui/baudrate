defmodule Baudrate.Federation.CollectionsQueryCountTest do
  @moduledoc """
  Phase 8D: a page of an ActivityPub collection costs a bounded number of
  queries, whatever it holds.

  The outboxes built each item with queries of its own — the associations
  `ObjectBuilder.article_object/1` preloads, the comment and like counts, and
  whether the article was ever edited — so a 20-item page cost about 160.
  `ObjectBuilder.article_objects/1` computes all of that for the whole page at
  once. These tests count the queries a page issues and fail when the count
  grows with the number of items.
  """

  use Baudrate.DataCase, async: true

  alias Baudrate.Content
  alias Baudrate.Federation.Collections

  @handler "collections-query-count"

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    board =
      %Content.Board{}
      |> Content.Board.changeset(%{
        name: "Federated",
        slug: "fed-#{System.unique_integer([:positive])}",
        min_role_to_view: "guest",
        ap_enabled: true
      })
      |> Repo.insert!()

    user = BaudrateWeb.ConnCase.setup_user("user")
    %{board: board, user: user}
  end

  defp post(user, board, n) do
    for i <- 1..n do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Article #{i}",
            body: "Body #{i} with #tag#{i}",
            slug: "q-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      article
    end
  end

  # Counts the queries this process issues while `fun` runs.
  defp count_queries(fun) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      {@handler, ref},
      [:baudrate, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, {ref, :query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach({@handler, ref})
    end
  end

  defp drain(ref, n) do
    receive do
      {^ref, :query} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  # The same page with 2 items and with 20 must cost the same number of
  # queries (give or take one for a query that only runs when there is
  # something to look up), and stay small.
  defp assert_bounded(small, large) do
    assert large <= small + 1,
           "a page of 20 cost #{large} queries against #{small} for a page of 2"

    assert large <= 20, "a page cost #{large} queries"
  end

  test "a user outbox page", %{board: board, user: user} do
    post(user, board, 2)
    {page, small} = count_queries(fn -> Collections.user_outbox(user, %{"page" => "1"}) end)
    assert length(page["orderedItems"]) == 2

    post(user, board, 18)
    {page, large} = count_queries(fn -> Collections.user_outbox(user, %{"page" => "1"}) end)
    assert length(page["orderedItems"]) == 20

    assert_bounded(small, large)
  end

  test "a search page", %{board: board, user: user} do
    post(user, board, 2)

    {page, small} =
      count_queries(fn -> Collections.search_collection("Body", %{"page" => "1"}) end)

    assert length(page["orderedItems"]) == 2

    post(user, board, 18)

    {page, large} =
      count_queries(fn -> Collections.search_collection("Body", %{"page" => "1"}) end)

    assert length(page["orderedItems"]) == 20

    assert_bounded(small, large)
  end

  test "a board outbox page", %{board: board, user: user} do
    post(user, board, 2)
    {page, small} = count_queries(fn -> Collections.board_outbox(board, %{"page" => "1"}) end)
    assert length(page["orderedItems"]) == 2

    post(user, board, 18)
    {page, large} = count_queries(fn -> Collections.board_outbox(board, %{"page" => "1"}) end)
    assert length(page["orderedItems"]) == 20

    assert_bounded(small, large)
  end
end
