defmodule BaudrateWeb.Features.BrowsingTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "home to board to article navigation flow", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Browse Board"})
    article = create_article(user, board, %{title: "Browse Article"})

    session
    |> visit("/")
    |> click(Query.link("Browse Board"))
    |> assert_has(Query.css("h1", text: "Browse Board"))
    |> click(Query.link(article.title))
    |> assert_has(Query.css("h1", text: article.title))
  end

  feature "empty board shows no articles message", %{session: session} do
    board = create_board(%{name: "Empty Board"})

    session
    |> visit("/boards/#{board.slug}")
    |> assert_has(Query.css("h1", text: "Empty Board"))
    |> assert_has(Query.text("No articles yet."))
  end

  feature "article page shows author and comments section", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Author Board"})
    article = create_article(user, board, %{title: "Author Article"})

    session
    |> visit("/articles/#{article.slug}")
    |> assert_has(Query.css("h1", text: article.title))
    |> assert_has(Query.link(user.username))
    |> assert_has(Query.css("h2", text: "Comments"))
  end
end
