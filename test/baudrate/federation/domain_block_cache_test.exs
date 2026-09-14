defmodule Baudrate.Federation.DomainBlockCacheTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation.DomainBlockCache
  alias Baudrate.Setup

  setup do
    DomainBlockCache.refresh()
    :ok
  end

  # `domain_blocked?/1` reads the database while the settings cache is off in
  # tests, so these read the ETS entry that production uses.
  defp cached_config, do: :ets.lookup(:domain_block_cache, :domain_config)

  describe "cache refresh on setting writes" do
    test "writing the blocklist updates the cache without an explicit refresh" do
      Setup.set_setting("ap_federation_mode", "blocklist")
      Setup.set_setting("ap_domain_blocklist", "fresh-block.example")

      assert [{:domain_config, :blocklist, blocked}] = cached_config()
      assert MapSet.member?(blocked, "fresh-block.example")
    end

    test "switching to allowlist mode updates the cache" do
      Setup.set_setting("ap_domain_allowlist", "only.example")
      Setup.set_setting("ap_federation_mode", "allowlist")

      assert [{:domain_config, :allowlist, allowed}] = cached_config()
      assert MapSet.member?(allowed, "only.example")
    end
  end

  describe "domain_blocked?/1 with blocklist mode" do
    test "returns false when domain is not in blocklist" do
      refute DomainBlockCache.domain_blocked?("example.com")
    end

    test "returns true when domain is in blocklist" do
      Setup.set_setting("ap_federation_mode", "blocklist")
      Setup.set_setting("ap_domain_blocklist", "evil.example, spam.example")
      DomainBlockCache.refresh()

      assert DomainBlockCache.domain_blocked?("evil.example")
      assert DomainBlockCache.domain_blocked?("spam.example")
      refute DomainBlockCache.domain_blocked?("good.example")
    end

    test "is case-insensitive" do
      Setup.set_setting("ap_federation_mode", "blocklist")
      Setup.set_setting("ap_domain_blocklist", "Evil.Example")
      DomainBlockCache.refresh()

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
  end

  describe "refresh/0" do
    test "updates cache after settings change" do
      Setup.set_setting("ap_federation_mode", "blocklist")
      Setup.set_setting("ap_domain_blocklist", "bad.example")
      DomainBlockCache.refresh()

      assert DomainBlockCache.domain_blocked?("bad.example")

      # Update settings and refresh
      Setup.set_setting("ap_domain_blocklist", "other.example")
      DomainBlockCache.refresh()

      refute DomainBlockCache.domain_blocked?("bad.example")
      assert DomainBlockCache.domain_blocked?("other.example")
    end
  end
end
