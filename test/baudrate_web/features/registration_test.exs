defmodule BaudrateWeb.Features.RegistrationTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  setup do
    # Registration requires roles to be seeded (register_standard looks up "user" role)
    Baudrate.Setup.seed_roles_and_permissions()
    :ok
  end

  feature "successful registration shows recovery codes", %{session: session} do
    session
    |> visit("/register")
    |> fill_in(Query.css("#user_username"), with: "newuser_#{System.unique_integer([:positive])}")
    |> fill_in(Query.css("#user_password"), with: "Password123!x")
    |> fill_in(Query.css("#user_password_confirmation"), with: "Password123!x")
    |> click(Query.css("#user_terms_accepted"))
    |> click(Query.button("Sign Up"))
    |> assert_has(Query.css("h1", text: "Recovery Codes"))
    |> assert_has(Query.css(".grid.grid-cols-2"))
  end

  feature "acknowledging recovery codes redirects to login", %{session: session} do
    session
    |> visit("/register")
    |> fill_in(Query.css("#user_username"), with: "ackuser_#{System.unique_integer([:positive])}")
    |> fill_in(Query.css("#user_password"), with: "Password123!x")
    |> fill_in(Query.css("#user_password_confirmation"), with: "Password123!x")
    |> click(Query.css("#user_terms_accepted"))
    |> click(Query.button("Sign Up"))
    |> assert_has(Query.css("h1", text: "Recovery Codes"))
    |> click(Query.button("I have saved my recovery codes"))
    |> assert_has(Query.css("h1", text: "Sign In"))
  end
end
