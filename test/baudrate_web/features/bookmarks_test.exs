defmodule BaudrateWeb.Features.BookmarksTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "bookmarks page is accessible when logged in", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/bookmarks")
    |> assert_has(Query.css("h1", text: "Bookmarks"))
  end

  feature "bookmarks page shows empty state", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/bookmarks")
    |> assert_has(Query.text("No bookmarks"))
  end
end
