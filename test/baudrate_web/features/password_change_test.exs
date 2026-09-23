defmodule BaudrateWeb.Features.PasswordChangeTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  @new_password "Tr0ub4dor-and-Staple!"

  feature "a member changes their password, and only the new one signs in", %{
    session: session
  } do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/profile/password")
    |> fill_in(Query.css("#password_change_current_password"), with: "Password123!x")
    |> fill_in(Query.css("#password_change_password"), with: @new_password)
    |> fill_in(Query.css("#password_change_password_confirmation"), with: @new_password)
    |> click(Query.css("#password-change-submit"))
    |> assert_has(Query.text("Password changed. 0 other sessions were signed out."))
    |> wait_for_path("/profile/security")
    |> log_out_via_browser()
    |> submit_login_form(user, "Password123!x")
    |> assert_has(Query.text("Invalid username or password."))
    |> submit_login_form(user, @new_password)
    |> assert_has(Query.css("#home-welcome-heading"))
  end
end
