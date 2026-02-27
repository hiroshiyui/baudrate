defmodule BaudrateWeb.Features.LoginTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "successful login redirects to home", %{session: session} do
    user = setup_user("user")

    session
    |> visit("/login")
    |> fill_in(Query.css("#login_username"), with: user.username)
    |> fill_in(Query.css("#login_password"), with: "Password123!x")
    |> click(Query.button("Sign In"))
    |> assert_has(Query.css("h1", text: "Welcome, #{user.username}!"))
  end

  feature "failed login shows error", %{session: session} do
    user = setup_user("user")

    session
    |> visit("/login")
    |> fill_in(Query.css("#login_username"), with: user.username)
    |> fill_in(Query.css("#login_password"), with: "WrongPassword123!")
    |> click(Query.button("Sign In"))
    |> assert_has(Query.css(".alert", text: "Invalid username or password"))
  end

  feature "login page has registration link", %{session: session} do
    session
    |> visit("/login")
    |> assert_has(Query.link("Sign Up"))
  end

  feature "already authenticated user is redirected from login", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/login")
    |> assert_has(Query.css("h1", text: "Welcome, #{user.username}!"))
  end
end
