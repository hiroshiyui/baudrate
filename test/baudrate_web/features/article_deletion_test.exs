defmodule BaudrateWeb.Features.ArticleDeletionTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "author can see delete button on their article", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Delete Board"})
    article = create_article(user, board, %{title: "Article To Delete"})

    session
    |> log_in_via_browser(user)
    |> visit("/articles/#{article.slug}")
    |> assert_has(Query.css("h1", text: "Article To Delete"))
    # Open the more actions dropdown
    |> click(Query.css("button[aria-label='More actions']"))
    |> assert_has(Query.css("button[phx-click='delete_article']"))
  end

  feature "non-author cannot see delete button", %{session: session} do
    author = setup_user("user")
    board = create_board(%{name: "Other Delete Board"})
    article = create_article(author, board, %{title: "Not My Article"})

    other_user = setup_user("user")

    session
    |> log_in_via_browser(other_user)
    |> visit("/articles/#{article.slug}")
    |> assert_has(Query.css("h1", text: "Not My Article"))
    |> refute_has(Query.css("button[phx-click='delete_article']"))
  end

  feature "guest cannot see delete button", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Guest Delete Board"})
    article = create_article(user, board, %{title: "Undeletable Article"})

    session
    |> visit("/articles/#{article.slug}")
    |> assert_has(Query.css("h1", text: "Undeletable Article"))
    |> refute_has(Query.css("button[phx-click='delete_article']"))
  end
end
