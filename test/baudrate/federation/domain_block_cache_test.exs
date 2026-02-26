defmodule Baudrate.Federation.DomainBlockCacheTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation.DomainBlockCache
  alias Baudrate.Setup

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
