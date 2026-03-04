defmodule BaudrateWeb.Features.CommentsTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "authenticated user can post a comment", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Comment Board"})
    article = create_article(user, board, %{title: "Commentable Article"})

    session
    |> log_in_via_browser(user)
    |> visit("/articles/#{article.slug}")
    |> fill_in(Query.css("#comment-body"), with: "This is a test comment.")
    |> click(Query.button("Post Comment"))
    |> assert_has(Query.text("This is a test comment."))
  end

  feature "guest cannot post comments", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "GuestComment Board"})
    article = create_article(user, board, %{title: "Guest Article"})

    session
    |> visit("/articles/#{article.slug}")
    |> assert_has(Query.css("h2", text: "Comments"))
    |> refute_has(Query.css("#comment-body"))
  end
end
