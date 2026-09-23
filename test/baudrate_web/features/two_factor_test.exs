defmodule BaudrateWeb.Features.TwoFactorTest do
  use BaudrateWeb.FeatureCase, async: false

  alias Baudrate.{Auth, Repo}

  @moduletag :feature

  feature "a moderator enrolls in TOTP at first sign-in, after a wrong code", %{
    session: session
  } do
    moderator = setup_user("moderator")

    session =
      session
      |> submit_login_form(moderator, "Password123!x")
      |> assert_has(Query.css("#totp-manual-key"))

    secret =
      session
      |> find(Query.css("#totp-manual-key"))
      |> Wallaby.Element.text()
      |> String.trim()
      |> Base.decode32!(padding: false)

    session
    |> fill_in(Query.css("#totp_code"), with: wrong_code(secret))
    |> click(Query.css("#totp-setup-submit"))
    |> assert_has(Query.text("Invalid verification code. Please try again."))
    |> fill_in(Query.css("#totp_code"), with: NimbleTOTP.verification_code(secret))
    |> click(Query.css("#totp-setup-submit"))
    |> assert_has(Query.text("Two-factor authentication enabled successfully."))
    |> wait_for_path("/profile/security")

    assert Repo.reload!(moderator).totp_enabled
  end

  feature "a wrong TOTP code at sign-in is refused and the right one signs in", %{
    session: session
  } do
    {user, secret} = enable_totp!(setup_user("user"))

    session
    |> submit_login_form(user, "Password123!x")
    |> fill_in(Query.css("#totp_code"), with: wrong_code(secret))
    |> click(Query.css("#totp-verify-submit"))
    |> assert_has(Query.text("Invalid verification code. Please try again."))
    |> fill_in(Query.css("#totp_code"), with: totp_code(user, secret))
    |> click(Query.css("#totp-verify-submit"))
    |> assert_has(Query.css("#home-welcome-heading"))
  end

  feature "a recovery code signs in once and is refused the second time", %{session: session} do
    {user, _secret} = enable_totp!(setup_user("user"))
    [code | _] = Auth.generate_recovery_codes(user)

    session
    |> sign_in_with_recovery_code(user, code)
    |> assert_has(Query.css("#home-welcome-heading"))
    |> log_out_via_browser()
    |> sign_in_with_recovery_code(user, code)
    |> assert_has(Query.text("Invalid recovery code. Please try again."))
    |> wait_for_path("/totp/recovery")
  end

  defp sign_in_with_recovery_code(session, user, code) do
    session
    |> submit_login_form(user, "Password123!x")
    |> click(Query.css("#totp-verify-recovery-link"))
    |> fill_in(Query.css("#recovery_code"), with: code)
    |> click(Query.css("#recovery-code-verify-submit"))
  end

  # A code for neither the current nor (almost surely) the previous period:
  # every digit of the current code shifted by one.
  defp wrong_code(secret) do
    secret
    |> NimbleTOTP.verification_code()
    |> String.graphemes()
    |> Enum.map_join(fn digit -> Integer.to_string(rem(String.to_integer(digit) + 1, 10)) end)
  end
end
