defmodule Baudrate.Auth.LoginAttemptTest do
  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Auth.LoginAttempt
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  describe "record_login_attempt/3" do
    test "records a failed login attempt" do
      assert {:ok, attempt} = Auth.record_login_attempt("TestUser", "127.0.0.1", false)
      assert attempt.username == "testuser"
      assert attempt.ip_address == "127.0.0.1"
      assert attempt.success == false
      assert attempt.inserted_at
    end

    test "records a successful login attempt" do
      assert {:ok, attempt} = Auth.record_login_attempt("TestUser", "127.0.0.1", true)
      assert attempt.username == "testuser"
      assert attempt.success == true
    end

    test "lowercases username for case-insensitive matching" do
      {:ok, attempt} = Auth.record_login_attempt("MiXeDcAsE", "127.0.0.1", false)
      assert attempt.username == "mixedcase"
    end
  end

  describe "check_login_throttle/1" do
    test "returns :ok with no failures" do
      assert :ok = Auth.check_login_throttle("clean_user")
    end

    test "returns :ok with fewer than 5 failures" do
      for _ <- 1..4 do
        Auth.record_login_attempt("few_failures", "127.0.0.1", false)
      end

      assert :ok = Auth.check_login_throttle("few_failures")
    end

    test "returns {:delay, _} after 5 failures" do
      for _ <- 1..5 do
        Auth.record_login_attempt("throttled5", "127.0.0.1", false)
      end

      assert {:delay, seconds} = Auth.check_login_throttle("throttled5")
      assert seconds > 0
      assert seconds <= 5
    end

    test "returns {:delay, _} after 10 failures with longer delay" do
      for _ <- 1..10 do
        Auth.record_login_attempt("throttled10", "127.0.0.1", false)
      end

      assert {:delay, seconds} = Auth.check_login_throttle("throttled10")
      assert seconds > 5
      assert seconds <= 30
    end

    test "returns {:delay, _} after 15 failures with longest delay" do
      for _ <- 1..15 do
        Auth.record_login_attempt("throttled15", "127.0.0.1", false)
      end

      assert {:delay, seconds} = Auth.check_login_throttle("throttled15")
      assert seconds > 30
      assert seconds <= 120
    end

    test "is case-insensitive" do
      for _ <- 1..5 do
        Auth.record_login_attempt("CaseTest", "127.0.0.1", false)
      end

      assert {:delay, _} = Auth.check_login_throttle("casetest")
      assert {:delay, _} = Auth.check_login_throttle("CASETEST")
    end

    test "returns :ok after delay period has elapsed" do
      # Insert old failures (more than 5 seconds ago)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      past = DateTime.add(now, -10, :second)

      for _ <- 1..5 do
        Repo.insert!(%LoginAttempt{
          username: "old_failures",
          ip_address: "127.0.0.1",
          success: false,
          inserted_at: past
        })
      end

      # 5 failures with 5s delay, but last failure was 10s ago → should be ok
      assert :ok = Auth.check_login_throttle("old_failures")
    end

    test "does not count successful attempts as failures" do
      for _ <- 1..4 do
        Auth.record_login_attempt("mixed_results", "127.0.0.1", false)
      end

      Auth.record_login_attempt("mixed_results", "127.0.0.1", true)

      assert :ok = Auth.check_login_throttle("mixed_results")
    end
  end

  describe "paginate_login_attempts/1" do
    test "returns paginated results" do
      for i <- 1..3 do
        Auth.record_login_attempt("page_user_#{i}", "127.0.0.1", false)
      end

      result = Auth.paginate_login_attempts(per_page: 2)
      assert length(result.attempts) == 2
      assert result.total == 3
      assert result.total_pages == 2

      result2 = Auth.paginate_login_attempts(per_page: 2, page: 2)
      assert length(result2.attempts) == 1
    end

    test "filters by username" do
      Auth.record_login_attempt("alice", "127.0.0.1", false)
      Auth.record_login_attempt("bob", "127.0.0.1", false)
      Auth.record_login_attempt("alice_admin", "127.0.0.1", true)

      result = Auth.paginate_login_attempts(username: "alice")
      assert result.total == 2
      assert Enum.all?(result.attempts, &String.contains?(&1.username, "alice"))
    end

    test "returns newest first" do
      Auth.record_login_attempt("order_test", "127.0.0.1", false)
      Auth.record_login_attempt("order_test", "127.0.0.1", true)

      result = Auth.paginate_login_attempts(username: "order_test")
      assert length(result.attempts) == 2
      [first, second] = result.attempts
      assert DateTime.compare(first.inserted_at, second.inserted_at) in [:gt, :eq]
    end
  end

  describe "purge_old_login_attempts/0" do
    test "removes records older than 7 days" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old = DateTime.add(now, -8 * 86_400, :second)

      # Insert old record directly
      Repo.insert!(%LoginAttempt{
        username: "old_user",
        ip_address: "127.0.0.1",
        success: false,
        inserted_at: old
      })

      # Insert recent record
      Auth.record_login_attempt("recent_user", "127.0.0.1", false)

      {count, _} = Auth.purge_old_login_attempts()
      assert count == 1

      result = Auth.paginate_login_attempts()
      assert result.total == 1
      assert hd(result.attempts).username == "recent_user"
    end
  end
end
