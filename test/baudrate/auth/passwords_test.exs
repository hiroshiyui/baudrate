defmodule Baudrate.Auth.PasswordsTest do
  @moduledoc """
  The two unauthenticated password paths must not say, by how long they
  take, whether a username exists. Bcrypt dominates their cost, so the rule
  is checked as a count: every path spends **exactly one** bcrypt
  computation.

  Timing is not measured — the suite runs bcrypt at its lowest cost, and a
  wall-clock test would be both meaningless and flaky. Instead the test
  process traces the two functions every bcrypt computation passes through:
  `Bcrypt.verify_pass/2` (checking a stored hash) and
  `Bcrypt.Base.hash_password/2` (hashing, which `Bcrypt.no_user_verify/0`
  does too). Only this process is traced, so concurrent tests are unaffected.

  Sign-in used to cost two for a known account with a wrong password
  (`verify_pass/2`, then `no_user_verify/0` as well) and one for an unknown
  name. The recovery-code reset cost one for an unknown name and none for a
  known one with a wrong code, since a code is checked by HMAC.
  """

  use Baudrate.DataCase, async: true

  alias Baudrate.Auth

  @traced [{Bcrypt, :verify_pass, 2}, {Bcrypt.Base, :hash_password, 2}]

  # A process cannot be its own tracer, and a pattern set on a module that is
  # not loaded yet is silently dropped (`Bcrypt.Base` loads its NIF lazily),
  # so the counting happens in a separate process after both are loaded.
  # `trace_delivered/1` waits until every trace message has reached it.
  defp bcrypt_count(fun) do
    Enum.each(@traced, fn {mod, _, _} = mfa ->
      Code.ensure_loaded!(mod)
      1 = :erlang.trace_pattern(mfa, true, [:global])
    end)

    tracer = spawn_link(fn -> count_calls(0) end)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
    end

    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _, ^ref}
    send(tracer, {:report, self()})
    assert_receive {:bcrypt_count, n}
    n
  end

  defp count_calls(n) do
    receive do
      {:trace, _pid, :call, _mfa} -> count_calls(n + 1)
      {:report, pid} -> send(pid, {:bcrypt_count, n})
    end
  end

  defp user_with_codes do
    user = BaudrateWeb.ConnCase.setup_user("user")
    {user, Auth.generate_recovery_codes(user)}
  end

  describe "authenticate_by_password/2" do
    test "costs one bcrypt whether or not the account exists" do
      user = BaudrateWeb.ConnCase.setup_user("user")

      unknown =
        bcrypt_count(fn ->
          assert {:error, :invalid_credentials} =
                   Auth.authenticate_by_password("no_such_user_x", "Wrong1!pass")
        end)

      wrong_password =
        bcrypt_count(fn ->
          assert {:error, :invalid_credentials} =
                   Auth.authenticate_by_password(user.username, "Wrong1!pass")
        end)

      right_password =
        bcrypt_count(fn ->
          assert {:ok, _} = Auth.authenticate_by_password(user.username, "Password123!x")
        end)

      assert {unknown, wrong_password, right_password} == {1, 1, 1}
    end
  end

  describe "reset_password_with_recovery_code/4" do
    test "costs one bcrypt whether or not the account exists" do
      {user, [code | _]} = user_with_codes()

      unknown =
        bcrypt_count(fn ->
          assert {:error, :invalid_credentials} =
                   Auth.reset_password_with_recovery_code(
                     "no_such_user_x",
                     "abcd-efgh",
                     "NewSecure1!!x",
                     "NewSecure1!!x"
                   )
        end)

      wrong_code =
        bcrypt_count(fn ->
          assert {:error, :invalid_credentials} =
                   Auth.reset_password_with_recovery_code(
                     user.username,
                     "zzzz-zzzz",
                     "NewSecure1!!x",
                     "NewSecure1!!x"
                   )
        end)

      right_code =
        bcrypt_count(fn ->
          assert {:ok, _} =
                   Auth.reset_password_with_recovery_code(
                     user.username,
                     code,
                     "NewSecure1!!x",
                     "NewSecure1!!x"
                   )
        end)

      assert {unknown, wrong_code, right_code} == {1, 1, 1}
    end

    test "a password the policy refuses spends no code" do
      {user, [code | _]} = user_with_codes()

      assert {:error, %Ecto.Changeset{}} =
               Auth.reset_password_with_recovery_code(user.username, code, "short", "short")

      assert {:error, %Ecto.Changeset{}} =
               Auth.reset_password_with_recovery_code(
                 user.username,
                 code,
                 "NewSecure1!!x",
                 "Mismatch1!!xy"
               )

      # The same code still works.
      assert {:ok, _} =
               Auth.reset_password_with_recovery_code(
                 user.username,
                 code,
                 "NewSecure1!!x",
                 "NewSecure1!!x"
               )
    end

    test "a refused password answers the same for an unknown account" do
      {user, [code | _]} = user_with_codes()

      known =
        Auth.reset_password_with_recovery_code(user.username, code, "short", "short")

      unknown =
        Auth.reset_password_with_recovery_code("no_such_user_x", "abcd-efgh", "short", "short")

      assert {:error, %Ecto.Changeset{} = a} = known
      assert {:error, %Ecto.Changeset{} = b} = unknown
      assert errors_on(a) == errors_on(b)
    end

    test "matches the username case-insensitively, like sign-in" do
      {user, [code | _]} = user_with_codes()

      assert {:ok, _} =
               Auth.reset_password_with_recovery_code(
                 String.upcase(user.username),
                 code,
                 "NewSecure1!!x",
                 "NewSecure1!!x"
               )
    end
  end
end
