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
    |> click(Query.css("form button[type=submit]"))
    |> assert_has(Query.text("Elixir Concurrency Guide"))
  end

  feature "search shows no results message for unmatched query", %{session: session} do
    session
    |> visit("/search?q=zzzznonexistent999")
    |> assert_has(Query.text("No articles found"))
  end

  feature "search by author operator", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Author Search Board"})
    create_article(user, board, %{title: "Author Test Article"})

    session
    |> visit("/search?q=author:#{user.username}")
    |> assert_has(Query.text("Author Test Article"))
  end

  feature "the filter controls narrow a search through the query string", %{session: session} do
    user = setup_user("user")
    here = create_board(%{name: "Filtered Board"})
    elsewhere = create_board(%{name: "Other Board"})
    create_article(user, here, %{title: "Kestrel In Range"})
    create_article(user, elsewhere, %{title: "Kestrel Out Of Range"})

    session
    |> visit("/search?q=kestrel")
    |> assert_has(Query.text("Kestrel Out Of Range"))
    # A real click on a real <select>, because this control has to work with a
    # plain form submit — there is no phx-change behind it.
    |> click(Query.option("Filtered Board"))
    |> click(Query.css("#search-submit"))
    |> assert_has(Query.text("Kestrel In Range"))
    |> refute_has(Query.text("Kestrel Out Of Range"))
  end

  feature "the filters keep what the reader typed after a submit", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Sticky Board"})
    create_article(user, board, %{title: "Sticky Kestrel"})

    session
    |> visit("/search?q=kestrel")
    |> click(Query.option("Sticky Board"))
    |> click(Query.css("#search-submit"))
    # LiveView repaints every input on re-render, so a control that did not
    # render its value back would come back empty here.
    |> assert_has(Query.css("#search-query-input[value='kestrel board:#{board.slug}']"))
    |> assert_has(Query.css("#search-filter-board option[selected]"))
  end

  feature "a search with no scope says what to add", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "River Board"})
    create_article(user, board, %{title: "Would Be Listed By A River"})

    session
    |> visit("/search?q=after:2020-01-01")
    |> assert_has(Query.css("#search-no-scope"))
    |> refute_has(Query.text("Would Be Listed By A River"))
  end
end
