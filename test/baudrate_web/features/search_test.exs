defmodule BaudrateWeb.Features.SearchTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "search for articles by keyword", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Search Board"})
    create_article(user, board, %{title: "Elixir Concurrency Guide"})

    session
    |> visit("/search")
    |> fill_in(Query.css("input[name=q]"), with: "Concurrency")
    |> click(Query.button("", count: :any))
    |> assert_has(Query.text("Elixir Concurrency Guide"))
  end

  feature "search shows no results message for unmatched query", %{session: session} do
    session
    |> visit("/search?q=zzzznonexistent999")
    |> assert_has(Query.text("No results"))
  end

  feature "search by author operator", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Author Search Board"})
    create_article(user, board, %{title: "Author Test Article"})

    session
    |> visit("/search?q=author:#{user.username}")
    |> assert_has(Query.text("Author Test Article"))
  end
end
