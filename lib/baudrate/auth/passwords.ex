defmodule Baudrate.Auth.Passwords do
  @moduledoc """
  Handles password authentication, verification, and reset.
  """

  import Ecto.Query
  require Logger

  alias Baudrate.Repo
  alias Baudrate.Setup.User
  alias Baudrate.Auth.{Sanction, Sanctions, Sessions, SecondFactor}
  alias Baudrate.Notification.Hooks

  @doc """
  Authenticates a user by username and password.

  Returns `{:ok, user}` with role preloaded or `{:error, :invalid_credentials}`.

  Uses `Bcrypt.no_user_verify/0` on failed lookups to maintain constant-time
  behavior regardless of whether the username exists, preventing timing-based
  user enumeration.

  A suspension is refused here rather than per interaction, so every entry
  point inherits it (ADR 0029). `{:error, {:suspended, sanction}}` carries the
  row, because a member turned away must be told why and until when.
  """
  @spec authenticate_by_password(String.t(), String.t()) ::
          {:ok, User.t()}
          | {:error, :invalid_credentials | :banned | :bot_account | {:suspended, Sanction.t()}}
  def authenticate_by_password(username, password) do
    # Case-insensitively, like every other username lookup: the unique index is
    # on `lower(username)` and `check_login_throttle/1` downcases, so a
    # case-sensitive match here meant somebody who registered `Alice` and typed
    # `alice` got a generic refusal *and* burned a throttle slot against a name
    # the throttle had already folded.
    user =
      Repo.one(
        from u in User,
          where: fragment("lower(?)", u.username) == ^String.downcase(username),
          preload: :role
      )

    if user && Bcrypt.verify_pass(password, user.hashed_password) do
      cond do
        # Answers exactly as an unknown account does (ADR 0072). Its password
        # is random bytes, so this is belt and braces.
        user.status == "deleted" -> {:error, :invalid_credentials}
        user.is_bot -> {:error, :bot_account}
        user.status == "banned" -> {:error, :banned}
        true -> refuse_if_suspended(user)
      end
    else
      Bcrypt.no_user_verify()
      {:error, :invalid_credentials}
    end
  end

  defp refuse_if_suspended(%User{} = user) do
    case Sanctions.active_sanction(user, "suspend") do
      nil -> {:ok, user}
      sanction -> {:error, {:suspended, sanction}}
    end
  end

  @doc """
  Verifies a user's password. Returns `true` if the password matches,
  `false` otherwise. Uses constant-time comparison via bcrypt.
  """
  @spec verify_password(User.t() | nil, String.t() | nil) :: boolean()
  def verify_password(%User{hashed_password: hashed}, password) when is_binary(password) do
    Bcrypt.verify_pass(password, hashed)
  end

  def verify_password(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  @doc """
  Validates a password change for a signed-in user without applying it.

  The new password must satisfy the password policy, match its confirmation,
  and differ from the current password. Returns a changeset with
  `action: :validate`, so callers can show errors before running step-up
  re-authentication (which counts toward rate limits).
  """
  @spec password_change_changeset(User.t(), map()) :: Ecto.Changeset.t()
  def password_change_changeset(%User{} = user, attrs) do
    changeset = User.password_validation_changeset(user, attrs)
    new_password = Ecto.Changeset.get_change(changeset, :password)

    changeset =
      if changeset.valid? and is_binary(new_password) and
           Bcrypt.verify_pass(new_password, user.hashed_password) do
        Ecto.Changeset.add_error(
          changeset,
          :password,
          "must be different from your current password"
        )
      else
        changeset
      end

    %{changeset | action: :validate}
  end

  @doc """
  Changes the password of a signed-in user.

  **The caller must already have verified step-up re-authentication**
  (`Auth.verify_reauthentication/5`); this function does not re-check the
  current password.

  On success it:
    * stores the new password hash,
    * revokes every other session of the user (closing their LiveView
      sockets) and keeps the session row `keep_session_id`, so an attacker
      holding another session is signed out while the user stays signed in,
    * cancels any active data export request (ADR 0023) and pending account
      move (ADR 0025),
    * sends the always-delivered `password_changed` security notice.

  Returns `{:ok, user, revoked_session_count}` or `{:error, changeset}`.
  """
  @spec change_password(User.t(), map(), integer()) ::
          {:ok, User.t(), non_neg_integer()} | {:error, Ecto.Changeset.t()}
  def change_password(%User{} = user, attrs, keep_session_id) when is_integer(keep_session_id) do
    validation = password_change_changeset(user, attrs)

    if validation.valid? do
      case user |> User.password_reset_changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          revoked = Sessions.delete_other_sessions_for_user(user.id, keep_session_id)
          Baudrate.DataPortability.cancel_active_exports(user.id, "password_changed")
          Baudrate.AccountMigration.cancel_active_moves(user.id, "password_changed")
          Hooks.notify_account_security(user.id, "password_changed")

          Logger.info("auth.password_changed: user_id=#{user.id} revoked_sessions=#{revoked}")

          {:ok, updated, revoked}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, validation}
    end
  end

  @doc """
  Resets a user's password using a recovery code.

  Looks up the user by username, verifies the recovery code (consuming it),
  then updates the password. Returns generic errors to prevent user enumeration.
  """
  @spec reset_password_with_recovery_code(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials | Ecto.Changeset.t()}
  def reset_password_with_recovery_code(
        username,
        recovery_code,
        new_password,
        new_password_confirmation
      ) do
    user = Repo.one(from u in User, where: u.username == ^username, preload: :role)

    if is_nil(user) do
      # Constant-time: still hash to prevent timing attacks
      Bcrypt.no_user_verify()
      {:error, :invalid_credentials}
    else
      case SecondFactor.verify_recovery_code(user, recovery_code) do
        :ok ->
          changeset =
            User.password_reset_changeset(user, %{
              password: new_password,
              password_confirmation: new_password_confirmation
            })

          case Repo.update(changeset) do
            {:ok, user} ->
              Sessions.delete_all_sessions_for_user(user.id)
              Baudrate.DataPortability.cancel_active_exports(user.id, "password_changed")
              Baudrate.AccountMigration.cancel_active_moves(user.id, "password_changed")

              # `change_password/3` has always sent this; the recovery-code
              # path did not, which left the flow most likely to be somebody
              # else the only silent one.
              Hooks.notify_account_security(user.id, "password_changed")
              {:ok, user}

            {:error, changeset} ->
              {:error, changeset}
          end

        :error ->
          {:error, :invalid_credentials}
      end
    end
  end
end
