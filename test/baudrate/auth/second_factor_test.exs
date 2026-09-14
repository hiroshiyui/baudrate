defmodule Baudrate.Auth.SecondFactorTest do
  use Baudrate.DataCase, async: true

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Auth.{LoginAttempt, SecondFactor}
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Repo
  alias Baudrate.Setup

  @ip "203.0.113.20"

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "second_factor_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp user_with_totp do
    secret = Auth.generate_totp_secret()
    {:ok, user} = Auth.enable_totp(create_user(), secret)
    {user, secret}
  end

  # A fixed instant in the middle of a period, so step arithmetic is exact.
  @now 1_800_000_015
  defp code_at(secret, step), do: NimbleTOTP.verification_code(secret, time: step * 30)

  describe "match_totp_step/3" do
    test "accepts the current and the previous period, and returns the matched step" do
      secret = Auth.generate_totp_secret()
      current = SecondFactor.totp_step(@now)

      assert {:ok, ^current} =
               SecondFactor.match_totp_step(secret, code_at(secret, current), @now)

      previous = current - 1

      assert {:ok, ^previous} =
               SecondFactor.match_totp_step(secret, code_at(secret, previous), @now)
    end

    test "rejects older codes, codes from the future, and wrong codes" do
      secret = Auth.generate_totp_secret()
      current = SecondFactor.totp_step(@now)

      for step <- [current - 2, current + 1], code = code_at(secret, step) do
        # Six-digit codes can collide across periods; only test distinct ones.
        if code not in [code_at(secret, current), code_at(secret, current - 1)] do
          assert :error = SecondFactor.match_totp_step(secret, code, @now)
        end
      end

      assert :error = SecondFactor.match_totp_step(secret, "abcdef", @now)
      assert :error = SecondFactor.match_totp_step(secret, "12345", @now)
      assert :error = SecondFactor.match_totp_step(secret, nil, @now)
    end
  end

  describe "verify_totp_code/3" do
    test "a code works once" do
      {user, secret} = user_with_totp()
      code = totp_code(secret)

      assert SecondFactor.verify_totp_code(user, code)
      refute SecondFactor.verify_totp_code(user, code)
      assert is_integer(Repo.reload!(user).totp_last_used_step)
    end

    test "the previous period's code is refused once a newer code was used" do
      {user, secret} = user_with_totp()
      current = SecondFactor.totp_step()

      Repo.update_all(from(u in Setup.User, where: u.id == ^user.id),
        set: [totp_last_used_step: current]
      )

      previous_code = code_at(secret, current - 1)

      if previous_code != code_at(secret, current) do
        refute SecondFactor.verify_totp_code(user, previous_code)
      end
    end

    test "claim: false consumes nothing and returns false" do
      {user, secret} = user_with_totp()
      code = totp_code(secret)

      refute SecondFactor.verify_totp_code(user, code, claim: false)
      assert is_nil(Repo.reload!(user).totp_last_used_step)
      assert SecondFactor.verify_totp_code(user, code)
    end

    test "fails closed without TOTP or with a secret that cannot be decrypted" do
      {user, secret} = user_with_totp()
      code = totp_code(secret)

      {:ok, disabled} = Auth.disable_totp(user)
      refute SecondFactor.verify_totp_code(%{disabled | totp_secret: user.totp_secret}, code)

      {corrupt, corrupt_secret} = user_with_totp()
      corrupt = %{corrupt | totp_secret: "not ciphertext"}
      refute SecondFactor.verify_totp_code(corrupt, totp_code(corrupt_secret))
    end

    test "two requests racing with the same code cannot both succeed" do
      {user, secret} = user_with_totp()
      code = totp_code(secret)

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> SecondFactor.verify_totp_code(user, code) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, & &1) == 1
    end
  end

  describe "enable_totp/3 and disable_totp/1" do
    test "the code that confirmed enrolment is already used" do
      user = create_user()
      secret = Auth.generate_totp_secret()
      code = totp_code(secret)
      {:ok, step} = SecondFactor.match_totp_step(secret, code)

      {:ok, enabled} = Auth.enable_totp(user, secret, used_step: step)

      assert enabled.totp_last_used_step == step
      refute SecondFactor.verify_totp_code(enabled, code)
    end

    test "disabling TOTP forgets the last used period" do
      {user, secret} = user_with_totp()
      assert SecondFactor.verify_totp_code(user, totp_code(secret))

      {:ok, disabled} = Auth.disable_totp(Repo.reload!(user))
      assert is_nil(disabled.totp_last_used_step)
    end
  end

  describe "record_login_totp_failure/2" do
    defp totp_notices(user) do
      Repo.all(
        from(n in NotificationSchema,
          where: n.user_id == ^user.id and n.type == "totp_login_failed"
        )
      )
    end

    test "records a totp attempt that counts toward the login throttle" do
      {user, _secret} = user_with_totp()

      for _ <- 1..5, do: SecondFactor.record_login_totp_failure(user, @ip)

      assert [%LoginAttempt{factor: "totp", success: false, ip_address: @ip} | _] =
               Repo.all(from(a in LoginAttempt, where: a.username == ^user.username))

      assert {:delay, _} = Auth.check_login_throttle(user.username)
    end

    test "notifies the owner after 3 failures in an hour, at most once an hour" do
      {user, _secret} = user_with_totp()

      SecondFactor.record_login_totp_failure(user, @ip)
      SecondFactor.record_login_totp_failure(user, @ip)
      assert totp_notices(user) == []

      SecondFactor.record_login_totp_failure(user, @ip)
      assert [_] = totp_notices(user)

      SecondFactor.record_login_totp_failure(user, @ip)
      assert [notice] = totp_notices(user)

      # An hour later, failures that continue notify again.
      hour_ago = DateTime.utc_now() |> DateTime.add(-3601) |> DateTime.truncate(:second)

      Repo.update_all(from(n in NotificationSchema, where: n.id == ^notice.id),
        set: [inserted_at: hour_ago]
      )

      SecondFactor.record_login_totp_failure(user, @ip)
      assert length(totp_notices(user)) == 2
    end

    test "password and re-authentication failures never trigger the notice" do
      {user, _secret} = user_with_totp()

      for _ <- 1..3 do
        Auth.record_login_attempt(user.username, @ip, false)
        Auth.record_login_attempt(user.username, @ip, false, "reauth")
      end

      SecondFactor.record_login_totp_failure(user, @ip)
      assert totp_notices(user) == []
    end
  end
end
