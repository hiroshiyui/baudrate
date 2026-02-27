defmodule BaudrateWeb.Features.ArticleCreationTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "create article and view it", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Post Board"})

    unique = System.unique_integer([:positive])
    title = "My New Article #{unique}"

    session
    |> log_in_via_browser(user)
    |> visit("/boards/#{board.slug}/articles/new")
    |> fill_in(Query.css("#article_title"), with: title)
    |> fill_in(Query.css("#article_body"), with: "This is the body of my article.")
    |> click(Query.button("Create Article"))
    |> assert_has(Query.css("h1", text: title))
  end

  feature "new article link accessible from board page", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Link Board"})

    session
    |> log_in_via_browser(user)
    |> visit("/boards/#{board.slug}")
    |> assert_has(Query.link("New Article"))
  end
end
