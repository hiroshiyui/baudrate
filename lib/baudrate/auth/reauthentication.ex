defmodule Baudrate.Auth.Reauthentication do
  @moduledoc """
  Step-up re-authentication for sensitive actions taken from an
  already-authenticated session, such as managing security keys or resetting
  TOTP.

  A session cookie alone must never be enough to change how an account
  authenticates. Otherwise whoever holds a stolen cookie could enrol their own
  second factor, then use it to pass admin sudo mode or any later step-up
  check (see ADR 0022). Callers re-verify the account password, plus the
  current TOTP code when the account has TOTP enabled.

  ## Throttling

  Failed attempts are recorded in `login_attempts` under the account's
  username, so the per-account login throttle
  (`Baudrate.Auth.Sessions.check_login_throttle/1`) applies here too. It is
  enforced before any credential is checked and survives page reloads.
  Without it, a stolen session could guess the password through a
  re-authentication form and never hit the login throttle. Web-layer callers
  must also apply `BaudrateWeb.RateLimits.check_reauth/1` first.

  ## Codes are consumed

  A TOTP code accepted here is used up (`SecondFactor.verify_totp_code/3`,
  ADR 0024), so two checks within the same 30 seconds need two different
  codes. The code is consumed only when the password is also correct. A wrong
  password never burns the user's current code.

  Failures here never send the `totp_login_failed` notice: this form does not
  say which factor was wrong, and the notice would.

  ## Not accepted

  Recovery codes are deliberately not accepted. They exist to recover a lost
  device, and a leaked recovery sheet must not authorize changes to an
  account's factors.
  """

  require Logger

  alias Baudrate.Auth.{Passwords, SecondFactor, Sessions}
  alias Baudrate.Setup.User

  @doc """
  Verifies `password` (and `code`, when the user has TOTP enabled) for `user`.

  `ip_address` is recorded with failed attempts. `purpose` is an atom used only
  for logging (e.g. `:security_keys`, `:totp_reset`).

  Returns `:ok`, `{:error, :invalid_credentials}`, or
  `{:error, {:throttled, seconds_remaining}}` when the account is currently
  throttled by recent failures. A throttled call checks no credentials and
  records no attempt.
  """
  @spec verify(User.t(), String.t() | nil, String.t() | nil, String.t() | nil, atom()) ::
          :ok | {:error, :invalid_credentials} | {:error, {:throttled, pos_integer()}}
  def verify(%User{} = user, password, code, ip_address, purpose) when is_atom(purpose) do
    case Sessions.check_login_throttle(user.username) do
      {:delay, seconds} ->
        Logger.warning(
          "auth.reauth_throttled: user_id=#{user.id} purpose=#{purpose} ip=#{ip_address}"
        )

        {:error, {:throttled, seconds}}

      :ok ->
        do_verify(user, normalize(password), normalize(code), ip_address, purpose)
    end
  end

  defp do_verify(user, password, code, ip_address, purpose) do
    # Evaluate both factors unconditionally so response timing does not reveal
    # which one was wrong.
    password_valid = Passwords.verify_password(user, password)
    totp_valid = totp_valid?(user, String.trim(code), password_valid)

    if password_valid and totp_valid do
      Logger.info("auth.reauth_success: user_id=#{user.id} purpose=#{purpose} ip=#{ip_address}")
      :ok
    else
      Sessions.record_login_attempt(user.username, ip_address, false, "reauth")

      Logger.warning(
        "auth.reauth_failure: user_id=#{user.id} purpose=#{purpose} ip=#{ip_address}"
      )

      {:error, :invalid_credentials}
    end
  end

  # An account with TOTP enabled must present an unused code for the current or
  # previous time step. A secret that cannot be decrypted fails closed. The
  # code is consumed only when the password was right.
  defp totp_valid?(%User{totp_enabled: true} = user, code, password_valid) do
    SecondFactor.verify_totp_code(user, code, claim: password_valid)
  end

  defp totp_valid?(%User{}, _code, _password_valid), do: true

  defp normalize(value) when is_binary(value), do: value
  defp normalize(_), do: ""
end
