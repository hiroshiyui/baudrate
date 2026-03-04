defmodule BaudrateWeb.Features.UserProfileTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "user profile page shows username and stats", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Profile Board"})
    create_article(user, board, %{title: "Profile Article"})

    session
    |> visit("/users/#{user.username}")
    |> assert_has(Query.css("h1", text: user.username))
    |> assert_has(Query.text("Profile Article"))
  end

  feature "clicking author name navigates to profile", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "AuthorLink Board"})
    article = create_article(user, board, %{title: "AuthorLink Article"})

    session
    |> visit("/articles/#{article.slug}")
    |> click(Query.link(user.username))
    |> assert_has(Query.css("h1", text: user.username))
  end
end
