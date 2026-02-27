defmodule BaudrateWeb.Features.HomePageTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "guest sees welcome message and auth links", %{session: session} do
    session
    |> visit("/")
    |> assert_has(Query.text("Welcome to Baudrate"))
    |> assert_has(Query.link("sign in"))
    |> assert_has(Query.link("register"))
  end

  feature "guest sees board listing", %{session: session} do
    board = create_board(%{name: "General Discussion"})

    session
    |> visit("/")
    |> assert_has(Query.text("Boards"))
    |> assert_has(Query.text(board.name))
  end

  feature "authenticated user sees personalized greeting", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> assert_has(Query.css("h1", text: "Welcome, #{user.username}!"))
  end

  feature "board card navigates to board page", %{session: session} do
    create_board(%{name: "Navigable Board"})

    session
    |> visit("/")
    |> click(Query.link("Navigable Board"))
    |> assert_has(Query.css("h1", text: "Navigable Board"))
  end
end
