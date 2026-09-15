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

  # Fills the form top to bottom like a person: typing the new password used
  # to erase the username and recovery code, so every reset failed.
  feature "a member resets their password with a recovery code and signs in", %{
    session: session
  } do
    user = setup_user("user")
    [code | _] = Baudrate.Auth.generate_recovery_codes(user)
    new_password = "Tr0ub4dor-and-Staple!"

    session
    |> visit("/password-reset")
    |> fill_in(Query.css("#reset_username"), with: user.username)
    |> fill_in(Query.css("#reset_recovery_code"), with: code)
    |> fill_in(Query.css("#reset_new_password"), with: new_password)
    |> fill_in(Query.css("#reset_new_password_confirmation"), with: new_password)
    |> click(Query.css("#password-reset-submit"))
    |> assert_has(Query.text("Password reset successful! You can now sign in."))
    |> submit_login_form(user, new_password)
    |> assert_has(Query.css("#home-welcome-heading"))
  end

  feature "password reset form validates required fields", %{session: session} do
    session
    |> visit("/password-reset")
    |> click(Query.button("Reset Password"))
    # Browser native validation prevents submission — form stays on same page
    |> assert_has(Query.css("h1", text: "Reset Password"))
  end
end
