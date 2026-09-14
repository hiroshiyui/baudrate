defmodule Baudrate.Auth.SecondFactor do
  @moduledoc """
  Handles TOTP two-factor authentication and recovery codes.

  ## Verifying codes (ADR 0024)

  A code is accepted for the current 30-second time step or the previous one,
  and at most once per account: `verify_totp_code/3` records the accepted step
  in `users.totp_last_used_step` and refuses any step that is not later.
  Every path that signs someone in or authorizes a change with a stored secret
  must go through it. A failed code at the login step is recorded with
  `record_login_totp_failure/2`, which feeds the per-account login throttle.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Auth.{LoginAttempt, RecoveryCode, Sessions, TotpVault}
  alias Baudrate.Notification.Hooks
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Setup.User

  @recovery_code_count 10
  @totp_period 30
  @totp_failure_notice_threshold 3
  @totp_failure_window_seconds 3600

  @doc """
  Returns the TOTP policy for a given role name.

  - `:required` — admin, moderator must set up TOTP
  - `:optional` — user can optionally enable TOTP
  - `:disabled` — guest has no TOTP capability
  """
  @spec totp_policy(String.t()) :: :required | :optional | :disabled
  def totp_policy(role_name) when role_name in ["admin", "moderator"], do: :required
  def totp_policy("user"), do: :optional
  def totp_policy(_), do: :disabled

  @doc """
  Determines the next step after password authentication.

  This is the core state machine transition function. Given a user who has
  passed password auth, it returns the next state:

    * `:totp_verify` — user has TOTP enabled, needs to verify a code
    * `:totp_setup` — role requires TOTP but user hasn't enrolled yet
    * `:authenticated` — no TOTP needed, ready to establish a server-side session
  """
  @spec login_next_step(User.t()) :: :totp_verify | :totp_setup | :authenticated
  def login_next_step(user) do
    cond do
      user.totp_enabled -> :totp_verify
      totp_policy(user.role.name) == :required -> :totp_setup
      true -> :authenticated
    end
  end

  @doc """
  Generates a new 20-byte TOTP secret.
  """
  def generate_totp_secret do
    NimbleTOTP.secret()
  end

  @doc """
  Builds an otpauth URI for QR code generation.
  """
  def totp_uri(secret, username, issuer \\ "Baudrate") do
    NimbleTOTP.otpauth_uri("#{issuer}:#{username}", secret, issuer: issuer)
  end

  @doc """
  Generates a Base64-encoded SVG data URI for QR code display.
  """
  def totp_qr_data_uri(uri) do
    svg =
      uri
      |> EQRCode.encode()
      |> EQRCode.svg(width: 264)

    "data:image/svg+xml;base64," <> Base.encode64(svg)
  end

  @doc """
  Returns the TOTP time step (period number) for a unix time in seconds.
  """
  @spec totp_step(integer()) :: integer()
  def totp_step(unix_seconds \\ System.os_time(:second)),
    do: Integer.floor_div(unix_seconds, @totp_period)

  @doc """
  Returns `{:ok, step}` when `code` is the code for the current time step or
  the one before it, or `:error`.

  The previous step is accepted so a code that rolls over while the user is
  typing still works (RFC 6238 §5.2 allows one step of network delay). Both
  steps are always computed. When the same code is valid for both, the later
  step wins.

  This checks the code only. It does not record the step, so on its own it
  gives no replay protection: sign-in paths must use `verify_totp_code/3`.
  Enrolment (`enable_totp/3`) uses it for a secret that is not stored yet.
  """
  @spec match_totp_step(binary(), term(), integer()) :: {:ok, integer()} | :error
  def match_totp_step(secret, code, now \\ System.os_time(:second))

  def match_totp_step(secret, code, now) when is_binary(secret) and is_binary(code) do
    current = totp_step(now)

    matches =
      Enum.map([current, current - 1], fn step ->
        {step, NimbleTOTP.valid?(secret, code, time: step * @totp_period)}
      end)

    case Enum.find(matches, fn {_step, valid} -> valid end) do
      {step, true} -> {:ok, step}
      nil -> :error
    end
  end

  def match_totp_step(_secret, _code, _now), do: :error

  @doc """
  Verifies a TOTP code for `user` and consumes it, so each code works once
  (ADR 0024, RFC 6238 §5.2).

  The code must match the current or previous time step (`match_totp_step/3`)
  **and** that step must be later than `users.totp_last_used_step`. The step is
  recorded with one conditional `UPDATE`, so two requests racing with the
  same code cannot both succeed. A replayed code, an older code after a newer
  one was used, TOTP being disabled, or a secret that cannot be decrypted all
  return `false`.

  ## Options

    * `:claim` — when `false`, nothing is consumed and the result is `false`.
      Step-up re-authentication passes whether the password was correct, so
      a wrong password never burns the user's current code. The `UPDATE` is
      issued either way, so response time does not reveal which factor failed.
  """
  @spec verify_totp_code(User.t(), term(), keyword()) :: boolean()
  def verify_totp_code(%User{} = user, code, opts \\ []) do
    claim? = Keyword.get(opts, :claim, true)

    step =
      with secret when is_binary(secret) <- decrypt_totp_secret(user),
           {:ok, step} <- match_totp_step(secret, code) do
        step
      else
        _ -> nil
      end

    claim_totp_step(user.id, claim? && step)
  end

  # Always issues the UPDATE; `step` is nil or false when there is nothing to claim.
  defp claim_totp_step(user_id, step) do
    claimable = is_integer(step)
    value = if claimable, do: step, else: -1

    {count, _} =
      from(u in User,
        where:
          u.id == ^user_id and u.totp_enabled == true and ^claimable and
            (is_nil(u.totp_last_used_step) or u.totp_last_used_step < ^value)
      )
      |> Repo.update_all(set: [totp_last_used_step: value])

    count == 1
  end

  @doc """
  Records a failed TOTP code at the login step and warns the account owner
  when it keeps happening.

  The TOTP step of login is only reached with the correct password, so
  failures here mean someone else may know it. The attempt is recorded in
  `login_attempts` with `factor: "totp"`, which puts it under the per-account
  login throttle. After #{@totp_failure_notice_threshold} such failures within an hour,
  the user gets a `totp_login_failed` security notice, at most once an hour.

  Step-up re-authentication must not call this. Its form never says which
  factor was wrong, and a notice would tell whoever holds the session that
  a guessed password was right.
  """
  @spec record_login_totp_failure(User.t(), String.t() | nil) :: :ok
  def record_login_totp_failure(%User{} = user, ip_address) do
    Sessions.record_login_attempt(user.username, ip_address, false, "totp")

    cutoff = DateTime.utc_now() |> DateTime.add(-@totp_failure_window_seconds, :second)
    username = String.downcase(user.username)

    failures =
      Repo.aggregate(
        from(a in LoginAttempt,
          where:
            a.username == ^username and a.factor == "totp" and a.success == false and
              a.inserted_at > ^cutoff
        ),
        :count
      )

    recently_notified? =
      Repo.exists?(
        from(n in NotificationSchema,
          where:
            n.user_id == ^user.id and n.type == "totp_login_failed" and
              n.inserted_at > ^cutoff
        )
      )

    if failures >= @totp_failure_notice_threshold and not recently_notified? do
      Hooks.notify_account_security(user.id, "totp_login_failed")
    end

    :ok
  end

  @doc """
  Enables TOTP for a user by encrypting the raw secret via `TotpVault.encrypt/1`
  and persisting the ciphertext alongside `totp_enabled: true`.

  The raw secret never touches the database — only the AES-256-GCM ciphertext
  is stored in `users.totp_secret`.

  Sends the user a `totp_enabled` account security notice (ADR 0022).

  ## Options

    * `:used_step` — the time step of the code that confirmed enrolment (from
      `match_totp_step/3`). It is recorded as already used, so that code
      cannot also sign in.
  """
  @spec enable_totp(User.t(), binary(), keyword()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def enable_totp(user, secret, opts \\ []) do
    encrypted = TotpVault.encrypt(secret)

    user
    |> User.totp_changeset(%{
      totp_secret: encrypted,
      totp_enabled: true,
      totp_enabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
      totp_last_used_step: Keyword.get(opts, :used_step)
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> Hooks.notify_account_security(updated.id, "totp_enabled")
      _ -> :ok
    end)
  end

  @doc """
  Returns `true` when the user has TOTP enabled and it was enabled at least
  `days` days ago (by `totp_enabled_at`).

  Features that must not trust a freshly enrolled factor use this. For
  example, self-service data export requires 7 days (ADR 0023), so an
  attacker who enrols their own authenticator on a compromised account cannot
  use it straight away. A user with TOTP enabled but no timestamp returns
  `false` (fail closed).
  """
  @spec totp_enabled_for_at_least?(User.t(), non_neg_integer()) :: boolean()
  def totp_enabled_for_at_least?(
        %User{totp_enabled: true, totp_enabled_at: %DateTime{} = enabled_at},
        days
      )
      when is_integer(days) and days >= 0 do
    DateTime.diff(DateTime.utc_now(), enabled_at, :second) >= days * 86_400
  end

  def totp_enabled_for_at_least?(%User{}, _days), do: false

  @doc """
  Decrypts a user's TOTP secret from the stored encrypted form.
  Returns the raw secret binary or nil.
  """
  @spec decrypt_totp_secret(User.t()) :: binary() | nil
  def decrypt_totp_secret(%User{totp_secret: nil}), do: nil

  def decrypt_totp_secret(%User{totp_secret: encrypted}) do
    case TotpVault.decrypt(encrypted) do
      {:ok, secret} -> secret
      :error -> nil
    end
  end

  @doc """
  Disables TOTP for a user by clearing the encrypted secret and setting
  `totp_enabled` to `false`.

  Sends a `totp_disabled` account security notice when TOTP was actually on.
  The TOTP reset flow disables and then re-enables, so it produces a
  `totp_disabled` and a `totp_enabled` notice. If the user abandons setup
  midway, the account is left without TOTP, and the first notice records that.
  """
  def disable_totp(user) do
    was_enabled = user.totp_enabled

    user
    |> User.totp_changeset(%{
      totp_secret: nil,
      totp_enabled: false,
      totp_enabled_at: nil,
      totp_last_used_step: nil
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} when was_enabled == true ->
        # Self-service export requires TOTP (ADR 0023); losing it cancels any request.
        Baudrate.DataPortability.cancel_active_exports(updated.id, "totp_changed")
        Hooks.notify_account_security(updated.id, "totp_disabled")

      _ ->
        :ok
    end)
  end

  @doc """
  Generates #{@recovery_code_count} one-time recovery codes for a user.

  Deletes any existing recovery codes, generates new cryptographically random
  codes (5 bytes → 8 base32 chars, ~41 bits of entropy each), stores their
  HMAC-SHA256 hashes, and returns the formatted codes (`xxxx-xxxx`) for
  one-time display to the user.
  """
  def generate_recovery_codes(user) do
    from(rc in RecoveryCode, where: rc.user_id == ^user.id)
    |> Repo.delete_all()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    raw_codes =
      Enum.map(1..@recovery_code_count, fn _ ->
        :crypto.strong_rand_bytes(5)
        |> Base.encode32(case: :lower, padding: false)
      end)

    entries =
      Enum.map(raw_codes, fn code ->
        %{
          user_id: user.id,
          code_hash: hmac_recovery_code(code),
          inserted_at: now
        }
      end)

    Repo.insert_all(RecoveryCode, entries)

    Enum.map(raw_codes, &format_recovery_code/1)
  end

  @doc """
  Verifies a recovery code for a user.

  Normalizes the input (strip whitespace, dashes, downcase), computes the
  HMAC-SHA256 hash, and atomically marks the matching unused code as used
  via `Repo.update_all` to prevent TOCTOU race conditions. Returns `:ok`
  if exactly one code was consumed, `:error` otherwise.
  """
  @spec verify_recovery_code(User.t(), String.t() | any()) :: :ok | :error
  def verify_recovery_code(user, code) when is_binary(code) do
    code_hash = hmac_recovery_code(normalize_recovery_code(code))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(rc in RecoveryCode,
        where: rc.user_id == ^user.id and rc.code_hash == ^code_hash and is_nil(rc.used_at)
      )

    case Repo.update_all(query, set: [used_at: now]) do
      {1, _} -> :ok
      {0, _} -> :error
    end
  end

  def verify_recovery_code(_, _), do: :error

  defp normalize_recovery_code(code) do
    code |> String.trim() |> String.downcase() |> String.replace("-", "")
  end

  defp format_recovery_code(code) do
    String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
  end

  defp hmac_recovery_code(code) do
    :crypto.mac(:hmac, :sha256, recovery_code_hmac_key(), code)
  end

  defp recovery_code_hmac_key do
    secret_key_base =
      Application.get_env(:baudrate, BaudrateWeb.Endpoint)[:secret_key_base]

    Plug.Crypto.KeyGenerator.generate(secret_key_base, "recovery_code_hmac_key", length: 32)
  end
end
