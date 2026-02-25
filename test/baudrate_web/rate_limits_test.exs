defmodule BaudrateWeb.RateLimitsTest do
  use ExUnit.Case, async: true

  import Mox

  alias BaudrateWeb.RateLimits

  setup do
    Mox.set_mox_private()
    :ok
  end

  setup :verify_on_exit!

  describe "check_create_article/1" do
    test "allows requests under the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:allow, 1} end)
      assert :ok = RateLimits.check_create_article(1)
    end

    test "denies requests over the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:deny, 10} end)
      assert {:error, :rate_limited} = RateLimits.check_create_article(1)
    end
  end

  describe "check_update_article/1" do
    test "allows requests under the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:allow, 1} end)
      assert :ok = RateLimits.check_update_article(1)
    end

    test "denies requests over the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:deny, 20} end)
      assert {:error, :rate_limited} = RateLimits.check_update_article(1)
    end
  end

  describe "check_create_comment/1" do
    test "allows requests under the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:allow, 1} end)
      assert :ok = RateLimits.check_create_comment(1)
    end

    test "denies requests over the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:deny, 30} end)
      assert {:error, :rate_limited} = RateLimits.check_create_comment(1)
    end
  end

  describe "check_delete_content/1" do
    test "allows requests under the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:allow, 1} end)
      assert :ok = RateLimits.check_delete_content(1)
    end

    test "denies requests over the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:deny, 20} end)
      assert {:error, :rate_limited} = RateLimits.check_delete_content(1)
    end
  end

  describe "check_mute_user/1" do
    test "allows requests under the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:allow, 1} end)
      assert :ok = RateLimits.check_mute_user(1)
    end

    test "denies requests over the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:deny, 10} end)
      assert {:error, :rate_limited} = RateLimits.check_mute_user(1)
    end
  end

  describe "check_search/1" do
    test "allows requests under the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:allow, 1} end)
      assert :ok = RateLimits.check_search(1)
    end

    test "denies requests over the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:deny, 15} end)
      assert {:error, :rate_limited} = RateLimits.check_search(1)
    end
  end

  describe "check_search_by_ip/1" do
    test "allows requests under the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:allow, 1} end)
      assert :ok = RateLimits.check_search_by_ip("10.0.0.1")
    end

    test "denies requests over the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:deny, 10} end)
      assert {:error, :rate_limited} = RateLimits.check_search_by_ip("10.0.0.1")
    end
  end

  describe "check_avatar_change/1" do
    test "allows requests under the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:allow, 1} end)
      assert :ok = RateLimits.check_avatar_change(1)
    end

    test "denies requests over the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:deny, 5} end)
      assert {:error, :rate_limited} = RateLimits.check_avatar_change(1)
    end
  end

  describe "check_dm_send/1" do
    test "allows requests under the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:allow, 1} end)
      assert :ok = RateLimits.check_dm_send(1)
    end

    test "denies requests over the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:deny, 20} end)
      assert {:error, :rate_limited} = RateLimits.check_dm_send(1)
    end
  end

  describe "check_outbound_follow/1" do
    test "allows requests under the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:allow, 1} end)
      assert :ok = RateLimits.check_outbound_follow(1)
    end

    test "denies requests over the limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l -> {:deny, 10} end)
      assert {:error, :rate_limited} = RateLimits.check_outbound_follow(1)
    end
  end

  describe "error path (fail-open)" do
    test "returns :ok on backend error" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l ->
        {:error, :backend_down}
      end)

      assert :ok = RateLimits.check_create_article(1)
    end

    test "logs error on backend failure" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _b, _s, _l ->
        {:error, :backend_down}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          RateLimits.check_create_article(1)
        end)

      assert log =~ "rate_limit.error"
      assert log =~ "backend_down"
    end
  end
end
