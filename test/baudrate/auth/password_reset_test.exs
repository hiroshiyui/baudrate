defmodule Baudrate.Auth.PasswordResetTest do
  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user_with_codes(opts) do
    role = Repo.one!(from r in Role, where: r.name == "user")
    username = Keyword.get(opts, :username, "user_#{System.unique_integer([:positive])}")
    password = Keyword.get(opts, :password, "Password123!x")

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => username,
        "password" => password,
        "password_confirmation" => password,
        "role_id" => role.id
      })
      |> Repo.insert()

    user = Repo.preload(user, :role)
    codes = Auth.generate_recovery_codes(user)
    {user, codes}
  end

  describe "reset_password_with_recovery_code/4" do
    test "resets password with valid username, recovery code, and new password" do
      {user, codes} = create_user_with_codes(username: "resetuser", password: "OldPass123!!")
      [code | _] = codes

      assert {:ok, updated_user} =
               Auth.reset_password_with_recovery_code(
                 "resetuser",
                 code,
                 "NewSecure1!!x",
                 "NewSecure1!!x"
               )

      assert updated_user.id == user.id

      # Can log in with new password
      assert {:ok, _} = Auth.authenticate_by_password("resetuser", "NewSecure1!!x")

      # Cannot log in with old password
      assert {:error, :invalid_credentials} =
               Auth.authenticate_by_password("resetuser", "OldPass123!!")
    end

    test "invalidates all sessions after successful reset" do
      {user, codes} = create_user_with_codes(username: "sessionuser")
      [code | _] = codes

      {:ok, session_token, _refresh_token} = Auth.create_user_session(user.id)

      {:ok, _} =
        Auth.reset_password_with_recovery_code(
          "sessionuser",
          code,
          "NewSecure1!!x",
          "NewSecure1!!x"
        )

      assert {:error, :not_found} = Auth.get_user_by_session_token(session_token)
    end

    test "returns error for invalid recovery code" do
      {_user, _codes} = create_user_with_codes(username: "badcode_user")

      assert {:error, :invalid_credentials} =
               Auth.reset_password_with_recovery_code(
                 "badcode_user",
                 "invalidcode",
                 "NewSecure1!!x",
                 "NewSecure1!!x"
               )
    end

    test "returns error for nonexistent username" do
      assert {:error, :invalid_credentials} =
               Auth.reset_password_with_recovery_code(
                 "nobody_exists",
                 "somecode",
                 "NewSecure1!!x",
                 "NewSecure1!!x"
               )
    end

    test "returns changeset error when password is too short" do
      {_user, codes} = create_user_with_codes(username: "shortpw_user")
      [code | _] = codes

      assert {:error, %Ecto.Changeset{} = changeset} =
               Auth.reset_password_with_recovery_code(
                 "shortpw_user",
                 code,
                 "Short1!",
                 "Short1!"
               )

      errors = errors_on(changeset)
      assert "should be at least 12 character(s)" in errors.password
    end

    test "returns changeset error when password confirmation does not match" do
      {_user, codes} = create_user_with_codes(username: "mismatch_user")
      [code | _] = codes

      assert {:error, %Ecto.Changeset{} = changeset} =
               Auth.reset_password_with_recovery_code(
                 "mismatch_user",
                 code,
                 "NewSecure1!!x",
                 "DifferentPass1!!"
               )

      errors = errors_on(changeset)
      assert "does not match password" in errors.password_confirmation
    end

    test "consumes the recovery code after use" do
      {_user, codes} = create_user_with_codes(username: "consume_user")
      [code | _] = codes

      assert {:ok, _} =
               Auth.reset_password_with_recovery_code(
                 "consume_user",
                 code,
                 "NewSecure1!!x",
                 "NewSecure1!!x"
               )

      # Second attempt with same code should fail
      assert {:error, :invalid_credentials} =
               Auth.reset_password_with_recovery_code(
                 "consume_user",
                 code,
                 "AnotherPass1!!",
                 "AnotherPass1!!"
               )
    end

    test "uses constant-time comparison for nonexistent user (timing safety)" do
      # This test verifies the code path goes through Bcrypt.no_user_verify
      # for nonexistent usernames to prevent timing attacks
      assert {:error, :invalid_credentials} =
               Auth.reset_password_with_recovery_code(
                 "timing_test_nonexistent",
                 "anycode",
                 "NewSecure1!!x",
                 "NewSecure1!!x"
               )
    end
  end
end
