defmodule BaudrateWeb.Features.SyndicatedArticleTest do
  @moduledoc """
  A syndicated article's collapsed rest (ADR 0081), in a real browser: the
  native disclosure opens and closes, and its label follows its state. Only a
  browser applies the `group-open:` CSS that switches the label.
  """

  use BaudrateWeb.FeatureCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Baudrate.{Content, Repo}

  @moduletag :feature

  feature "the rest opens and closes, and the toggle says which it will do", %{
    session: session
  } do
    board = create_board(%{name: "Feed Board"})
    bot = setup_user("user")
    Repo.update_all(from(u in Baudrate.Setup.User, where: u.id == ^bot.id), set: [is_bot: true])

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Feed entry",
          body: "First paragraph.\n\nSecond paragraph.",
          slug: "feed-entry-#{System.unique_integer([:positive])}",
          user_id: bot.id,
          url: "https://news.example/posts/1"
        },
        [board.id],
        trusted: true
      )

    session
    |> visit("/articles/#{article.slug}")
    |> assert_has(Query.css("[data-phx-main].phx-connected"))
    |> assert_has(Query.css("#article-body-rest-toggle", text: "Show the rest"))
    |> refute_has(Query.css("#article-body-rest .article-body", text: "Second paragraph."))
    |> click(Query.css("#article-body-rest-toggle"))
    |> assert_has(Query.css("#article-body-rest .article-body", text: "Second paragraph."))
    |> assert_has(Query.css("#article-body-rest-toggle", text: "Hide the rest"))
    |> refute_has(Query.css("#article-body-rest-toggle", text: "Show the rest"))
    |> click(Query.css("#article-body-rest-toggle"))
    |> assert_has(Query.css("#article-body-rest-toggle", text: "Show the rest"))
  end
end
