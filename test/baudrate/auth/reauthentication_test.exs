defmodule Baudrate.Auth.ReauthenticationTest do
  use Baudrate.DataCase, async: true

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Auth.LoginAttempt
  alias Baudrate.Repo
  alias Baudrate.Setup

  @password "Password123!x"
  @ip "203.0.113.7"

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "reauth_#{System.unique_integer([:positive])}",
        "password" => @password,
        "password_confirmation" => @password,
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp enable_totp(user) do
    secret = Auth.generate_totp_secret()
    {:ok, user} = Auth.enable_totp(user, secret)
    {user, secret}
  end

  defp failed_attempts(user) do
    Repo.aggregate(
      from(a in LoginAttempt, where: a.username == ^user.username and a.success == false),
      :count
    )
  end

  describe "verify_reauthentication/5 without TOTP" do
    test "accepts the correct password" do
      user = create_user()
      assert :ok = Auth.verify_reauthentication(user, @password, nil, @ip, :test)
      assert failed_attempts(user) == 0
    end

    test "rejects a wrong password and records a failed attempt with the IP" do
      user = create_user()

      assert {:error, :invalid_credentials} =
               Auth.verify_reauthentication(user, "wrong", nil, @ip, :test)

      assert [%LoginAttempt{success: false, ip_address: @ip}] =
               Repo.all(from(a in LoginAttempt, where: a.username == ^user.username))
    end

    test "treats a missing or non-string password as invalid" do
      user = create_user()

      assert {:error, :invalid_credentials} =
               Auth.verify_reauthentication(user, nil, nil, @ip, :test)

      assert {:error, :invalid_credentials} =
               Auth.verify_reauthentication(user, %{"x" => "y"}, nil, @ip, :test)
    end
  end

  describe "verify_reauthentication/5 with TOTP enabled" do
    test "requires a valid current code in addition to the password" do
      {user, secret} = user_with_totp()
      code = NimbleTOTP.verification_code(secret)

      assert :ok = Auth.verify_reauthentication(user, @password, code, @ip, :test)
    end

    test "rejects the correct password without a code" do
      {user, _secret} = user_with_totp()

      assert {:error, :invalid_credentials} =
               Auth.verify_reauthentication(user, @password, nil, @ip, :test)

      assert failed_attempts(user) == 1
    end

    test "rejects the correct password with a wrong code" do
      {user, _secret} = user_with_totp()

      assert {:error, :invalid_credentials} =
               Auth.verify_reauthentication(user, @password, "000000", @ip, :test)
    end

    test "rejects a valid code with a wrong password" do
      {user, secret} = user_with_totp()
      code = NimbleTOTP.verification_code(secret)

      assert {:error, :invalid_credentials} =
               Auth.verify_reauthentication(user, "wrong", code, @ip, :test)
    end

    test "does not accept a recovery code in place of the TOTP code" do
      {user, _secret} = user_with_totp()
      [recovery_code | _] = Auth.generate_recovery_codes(user)

      assert {:error, :invalid_credentials} =
               Auth.verify_reauthentication(user, @password, recovery_code, @ip, :test)
    end
  end

  describe "throttling" do
    test "refuses without checking credentials once the account is throttled" do
      user = create_user()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(
        LoginAttempt,
        for(
          _ <- 1..15,
          do: %{username: user.username, ip_address: @ip, success: false, inserted_at: now}
        )
      )

      # Even the correct password is refused while throttled, and no further
      # attempt is recorded.
      assert {:error, {:throttled, seconds}} =
               Auth.verify_reauthentication(user, @password, nil, @ip, :test)

      assert seconds > 0
      assert failed_attempts(user) == 15
    end

    test "failed re-authentication feeds the per-account login throttle" do
      user = create_user()

      for _ <- 1..5 do
        Auth.verify_reauthentication(user, "wrong", nil, @ip, :test)
      end

      assert {:delay, _seconds} = Auth.check_login_throttle(user.username)
    end
  end

  defp user_with_totp do
    enable_totp(create_user())
  end
end
