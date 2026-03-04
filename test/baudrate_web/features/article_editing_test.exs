defmodule BaudrateWeb.Features.ArticleEditingTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "author can edit their article", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Edit Board"})
    article = create_article(user, board, %{title: "Original Title", body: "Original body"})

    session
    |> log_in_via_browser(user)
    |> visit("/articles/#{article.slug}/edit")
    |> fill_in(Query.css("#article-title"), with: "Updated Title")
    |> click(Query.button("Save"))
    |> assert_has(Query.css("h1", text: "Updated Title"))
  end

  feature "non-author cannot access edit page", %{session: session} do
    author = setup_user("user")
    other = setup_user("user")
    board = create_board(%{name: "NoEdit Board"})
    article = create_article(author, board, %{title: "Protected Article"})

    session
    |> log_in_via_browser(other)
    |> visit("/articles/#{article.slug}")
    |> refute_has(Query.link("Edit"))
  end
end
