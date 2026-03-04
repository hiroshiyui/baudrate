defmodule BaudrateWeb.Features.PasswordResetTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  feature "password reset page is accessible from login", %{session: session} do
    session
    |> visit("/login")
    |> click(Query.link("Forgot your password?"))
    |> assert_has(Query.css("h1", text: "Reset Password"))
    |> assert_has(Query.css("#reset_username"))
    |> assert_has(Query.css("#reset_recovery_code"))
    |> assert_has(Query.css("#reset_new_password"))
  end

  feature "password reset form validates required fields", %{session: session} do
    session
    |> visit("/password-reset")
    |> click(Query.button("Reset Password"))
    # Browser native validation prevents submission — form stays on same page
    |> assert_has(Query.css("h1", text: "Reset Password"))
  end
end
