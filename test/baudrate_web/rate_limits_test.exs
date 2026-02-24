defmodule BaudrateWeb.RateLimitsTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.RateLimits

  # Each test uses a unique user_id to avoid cross-test interference
  # since Hammer ETS state persists within the test run.

  describe "check_create_article/1" do
    test "allows requests under the limit" do
      user_id = System.unique_integer([:positive])
      assert :ok = RateLimits.check_create_article(user_id)
    end

    test "denies requests over the limit" do
      user_id = System.unique_integer([:positive])

      for _ <- 1..10, do: assert(:ok == RateLimits.check_create_article(user_id))
      assert {:error, :rate_limited} = RateLimits.check_create_article(user_id)
    end
  end

  describe "check_update_article/1" do
    test "allows requests under the limit" do
      user_id = System.unique_integer([:positive])
      assert :ok = RateLimits.check_update_article(user_id)
    end

    test "denies requests over the limit" do
      user_id = System.unique_integer([:positive])

      for _ <- 1..20, do: assert(:ok == RateLimits.check_update_article(user_id))
      assert {:error, :rate_limited} = RateLimits.check_update_article(user_id)
    end
  end

  describe "check_create_comment/1" do
    test "allows requests under the limit" do
      user_id = System.unique_integer([:positive])
      assert :ok = RateLimits.check_create_comment(user_id)
    end

    test "denies requests over the limit" do
      user_id = System.unique_integer([:positive])

      for _ <- 1..30, do: assert(:ok == RateLimits.check_create_comment(user_id))
      assert {:error, :rate_limited} = RateLimits.check_create_comment(user_id)
    end
  end

  describe "check_delete_content/1" do
    test "allows requests under the limit" do
      user_id = System.unique_integer([:positive])
      assert :ok = RateLimits.check_delete_content(user_id)
    end

    test "denies requests over the limit" do
      user_id = System.unique_integer([:positive])

      for _ <- 1..20, do: assert(:ok == RateLimits.check_delete_content(user_id))
      assert {:error, :rate_limited} = RateLimits.check_delete_content(user_id)
    end
  end

  describe "check_mute_user/1" do
    test "allows requests under the limit" do
      user_id = System.unique_integer([:positive])
      assert :ok = RateLimits.check_mute_user(user_id)
    end

    test "denies requests over the limit" do
      user_id = System.unique_integer([:positive])

      for _ <- 1..10, do: assert(:ok == RateLimits.check_mute_user(user_id))
      assert {:error, :rate_limited} = RateLimits.check_mute_user(user_id)
    end
  end

  describe "check_search/1" do
    test "allows requests under the limit" do
      user_id = System.unique_integer([:positive])
      assert :ok = RateLimits.check_search(user_id)
    end

    test "denies requests over the limit" do
      user_id = System.unique_integer([:positive])

      for _ <- 1..15, do: assert(:ok == RateLimits.check_search(user_id))
      assert {:error, :rate_limited} = RateLimits.check_search(user_id)
    end
  end

  describe "check_search_by_ip/1" do
    test "allows requests under the limit" do
      ip = "10.#{:rand.uniform(255)}.#{:rand.uniform(255)}.#{:rand.uniform(255)}"
      assert :ok = RateLimits.check_search_by_ip(ip)
    end

    test "denies requests over the limit" do
      ip = "10.#{:rand.uniform(255)}.#{:rand.uniform(255)}.#{:rand.uniform(255)}"

      for _ <- 1..10, do: assert(:ok == RateLimits.check_search_by_ip(ip))
      assert {:error, :rate_limited} = RateLimits.check_search_by_ip(ip)
    end
  end

  describe "check_avatar_change/1" do
    test "allows requests under the limit" do
      user_id = System.unique_integer([:positive])
      assert :ok = RateLimits.check_avatar_change(user_id)
    end

    test "denies requests over the limit" do
      user_id = System.unique_integer([:positive])

      for _ <- 1..5, do: assert(:ok == RateLimits.check_avatar_change(user_id))
      assert {:error, :rate_limited} = RateLimits.check_avatar_change(user_id)
    end
  end

  describe "check_dm_send/1" do
    test "allows requests under the limit" do
      user_id = System.unique_integer([:positive])
      assert :ok = RateLimits.check_dm_send(user_id)
    end

    test "denies requests over the limit" do
      user_id = System.unique_integer([:positive])

      for _ <- 1..20, do: assert(:ok == RateLimits.check_dm_send(user_id))
      assert {:error, :rate_limited} = RateLimits.check_dm_send(user_id)
    end
  end
end
