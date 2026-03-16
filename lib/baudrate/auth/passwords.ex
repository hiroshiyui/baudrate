defmodule Baudrate.Auth.Passwords do
  @moduledoc """
  Handles password authentication, verification, and reset.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Setup.User
  alias Baudrate.Auth.{Sessions, SecondFactor}

  @doc """
  Authenticates a user by username and password.

  Returns `{:ok, user}` with role preloaded or `{:error, :invalid_credentials}`.

  Uses `Bcrypt.no_user_verify/0` on failed lookups to maintain constant-time
  behavior regardless of whether the username exists, preventing timing-based
  user enumeration.
  """
  @spec authenticate_by_password(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials | :banned | :bot_account}
  def authenticate_by_password(username, password) do
    user = Repo.one(from u in User, where: u.username == ^username, preload: :role)

    if user && Bcrypt.verify_pass(password, user.hashed_password) do
      cond do
        user.is_bot -> {:error, :bot_account}
        user.status == "banned" -> {:error, :banned}
        true -> {:ok, user}
      end
    else
      Bcrypt.no_user_verify()
      {:error, :invalid_credentials}
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
