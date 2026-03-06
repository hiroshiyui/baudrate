defmodule BaudrateWeb.Features.ArticleBookmarkTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "user can bookmark an article", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Bookmark Board"})
    article = create_article(user, board, %{title: "Bookmarkable Article"})

    session
    |> log_in_via_browser(user)
    |> visit("/articles/#{article.slug}")
    |> assert_has(Query.button("Bookmark"))
    |> click(Query.button("Bookmark"))
    |> assert_has(Query.button("Bookmarked"))
  end

  feature "user can remove a bookmark", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Unbookmark Board"})
    article = create_article(user, board, %{title: "Unbookmarkable Article"})

    session
    |> log_in_via_browser(user)
    |> visit("/articles/#{article.slug}")
    |> click(Query.button("Bookmark"))
    |> assert_has(Query.button("Bookmarked"))
    |> click(Query.button("Bookmarked"))
    |> assert_has(Query.button("Bookmark"))
  end

  feature "guest cannot see bookmark button", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Guest Bookmark Board"})
    article = create_article(user, board, %{title: "Guest Article"})

    session
    |> visit("/articles/#{article.slug}")
    |> refute_has(Query.css("button[phx-click='toggle_bookmark']"))
  end
end
