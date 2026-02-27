defmodule BaudrateWeb.Features.HomePageTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "visits the home page", %{session: session} do
    session
    |> visit("/")
    |> assert_has(Query.css("body"))
  end
end
