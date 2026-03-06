defmodule BaudrateWeb.Features.ArticleLikesTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "user can like another user's article", %{session: session} do
    author = setup_user("user")
    board = create_board(%{name: "Likes Board"})
    article = create_article(author, board, %{title: "Likeable Article"})

    liker = setup_user("user")

    session
    |> log_in_via_browser(liker)
    |> visit("/articles/#{article.slug}")
    |> assert_has(Query.button("0 Likes", at: 0, visible: true))
    |> click(Query.button("0 Likes"))
    |> assert_has(Query.button("1 Like", at: 0, visible: true))
  end

  feature "user can unlike an article", %{session: session} do
    author = setup_user("user")
    board = create_board(%{name: "Unlike Board"})
    article = create_article(author, board, %{title: "Unlikeable Article"})

    liker = setup_user("user")

    session
    |> log_in_via_browser(liker)
    |> visit("/articles/#{article.slug}")
    |> click(Query.button("0 Likes"))
    |> assert_has(Query.button("1 Like", at: 0, visible: true))
    |> click(Query.button("1 Like"))
    |> assert_has(Query.button("0 Likes", at: 0, visible: true))
  end

  feature "user cannot like own article", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Own Like Board"})
    article = create_article(user, board, %{title: "My Own Article"})

    session
    |> log_in_via_browser(user)
    |> visit("/articles/#{article.slug}")
    # Like button should not be present for own article
    |> refute_has(Query.css("button[phx-click='toggle_like']"))
  end
end
