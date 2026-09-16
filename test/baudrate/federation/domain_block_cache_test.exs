defmodule Baudrate.Federation.DomainBlockCacheTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation.{DomainBlockCache, DomainBlocks}
  alias Baudrate.Setup

  setup do
    DomainBlockCache.refresh()
    :ok
  end

  # `domain_blocked?/1` reads the database while the settings cache is off in
  # tests, so these read the ETS entry that production uses.
  defp cached_config, do: :ets.lookup(:domain_block_cache, :domain_config)

  describe "cache refresh on writes" do
    test "blocking a domain updates the cache without an explicit refresh" do
      Setup.set_setting("ap_federation_mode", "blocklist")
      {:ok, _} = DomainBlocks.block_domain("fresh-block.example")

      assert [{:domain_config, :blocklist, blocked}] = cached_config()
      assert MapSet.member?(blocked, "fresh-block.example")
    end

    test "unblocking a domain updates the cache without an explicit refresh" do
      Setup.set_setting("ap_federation_mode", "blocklist")
      {:ok, _} = DomainBlocks.block_domain("short-lived.example")
      {:ok, _} = DomainBlocks.unblock_domain("short-lived.example")

      assert [{:domain_config, :blocklist, blocked}] = cached_config()
      refute MapSet.member?(blocked, "short-lived.example")
    end

    test "switching to allowlist mode updates the cache" do
      Setup.set_setting("ap_domain_allowlist", "only.example")
      Setup.set_setting("ap_federation_mode", "allowlist")

      assert [{:domain_config, :allowlist, allowed}] = cached_config()
      assert MapSet.member?(allowed, "only.example")
    end
  end

  describe "domain_blocked?/1 with blocklist mode" do
    test "returns false when domain is not blocked" do
      refute DomainBlockCache.domain_blocked?("example.com")
    end

    test "returns true when domain is blocked" do
      Setup.set_setting("ap_federation_mode", "blocklist")
      {:ok, _} = DomainBlocks.block_domain("evil.example")
      {:ok, _} = DomainBlocks.block_domain("spam.example")

      assert DomainBlockCache.domain_blocked?("evil.example")
      assert DomainBlockCache.domain_blocked?("spam.example")
      refute DomainBlockCache.domain_blocked?("good.example")
    end

    test "is case-insensitive" do
      Setup.set_setting("ap_federation_mode", "blocklist")
      {:ok, block} = DomainBlocks.block_domain("Evil.Example")

      assert block.domain == "evil.example"
      assert DomainBlockCache.domain_blocked?("evil.example")
      assert DomainBlockCache.domain_blocked?("EVIL.EXAMPLE")
    end
  end

  describe "domain_blocked?/1 with allowlist mode" do
    test "blocks domains not in allowlist" do
      Setup.set_setting("ap_federation_mode", "allowlist")
      Setup.set_setting("ap_domain_allowlist", "trusted.example")
      DomainBlockCache.refresh()

      assert DomainBlockCache.domain_blocked?("untrusted.example")
      refute DomainBlockCache.domain_blocked?("trusted.example")
    end

    test "blocks all domains when allowlist is empty" do
      Setup.set_setting("ap_federation_mode", "allowlist")
      Setup.set_setting("ap_domain_allowlist", "")
      DomainBlockCache.refresh()

      assert DomainBlockCache.domain_blocked?("any.example")
    end

    test "a blocked domain row does not decide anything in allowlist mode" do
      # Allowlist mode is a configuration choice about who may reach us at all
      # (ADR 0030); the rows are moderation decisions and stay out of it.
      {:ok, _} = DomainBlocks.block_domain("blocked.example")
      Setup.set_setting("ap_domain_allowlist", "blocked.example")
      Setup.set_setting("ap_federation_mode", "allowlist")

      refute DomainBlockCache.domain_blocked?("blocked.example")
    end
  end

  describe "refresh/0" do
    test "updates cache after a block is lifted" do
      Setup.set_setting("ap_federation_mode", "blocklist")
      {:ok, _} = DomainBlocks.block_domain("bad.example")
      DomainBlockCache.refresh()

      assert DomainBlockCache.domain_blocked?("bad.example")

      {:ok, _} = DomainBlocks.unblock_domain("bad.example")
      {:ok, _} = DomainBlocks.block_domain("other.example")
      DomainBlockCache.refresh()

      refute DomainBlockCache.domain_blocked?("bad.example")
      assert DomainBlockCache.domain_blocked?("other.example")
    end
  end
end
