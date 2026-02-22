defmodule Baudrate.Federation.BlocklistAuditTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.BlocklistAudit
  alias Baudrate.Setup.Setting

  describe "parse_list/1" do
    test "parses JSON array of domain strings" do
      body = Jason.encode!(["bad.example", "evil.org", "spam.net"])
      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.size(domains) == 3
      assert MapSet.member?(domains, "bad.example")
      assert MapSet.member?(domains, "evil.org")
      assert MapSet.member?(domains, "spam.net")
    end

    test "parses JSON array with mixed types (filters non-strings)" do
      body = Jason.encode!(["valid.example", 42, nil, "also-valid.org", true])
      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.size(domains) == 2
      assert MapSet.member?(domains, "valid.example")
      assert MapSet.member?(domains, "also-valid.org")
    end

    test "normalizes JSON domains to lowercase and trims whitespace" do
      body = Jason.encode!(["  Bad.Example  ", "EVIL.ORG"])
      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.member?(domains, "bad.example")
      assert MapSet.member?(domains, "evil.org")
    end

    test "parses newline-separated domains" do
      body = "bad.example\nevil.org\nspam.net"
      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.size(domains) == 3
      assert MapSet.member?(domains, "bad.example")
    end

    test "handles Windows-style line endings (CRLF)" do
      body = "bad.example\r\nevil.org\r\nspam.net"
      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.size(domains) == 3
    end

    test "skips comment lines starting with #" do
      body = "# This is a comment\nbad.example\n# Another comment\nevil.org"
      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.size(domains) == 2
      assert MapSet.member?(domains, "bad.example")
      assert MapSet.member?(domains, "evil.org")
    end

    test "skips empty lines" do
      body = "bad.example\n\n\nevil.org\n\n"
      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.size(domains) == 2
    end

    test "parses Mastodon CSV export format (domain,severity,reason)" do
      body = """
      # Mastodon domain blocks
      bad.example,suspend,Known spam
      evil.org,silence,Harassment
      spam.net,suspend,
      """

      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.size(domains) == 3
      assert MapSet.member?(domains, "bad.example")
      assert MapSet.member?(domains, "evil.org")
      assert MapSet.member?(domains, "spam.net")
    end

    test "normalizes CSV domains to lowercase" do
      body = "Bad.Example,suspend,reason"
      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.member?(domains, "bad.example")
    end

    test "deduplicates domains" do
      body = Jason.encode!(["bad.example", "BAD.EXAMPLE", "bad.example"])
      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.size(domains) == 1
    end

    test "rejects empty strings from JSON array" do
      body = Jason.encode!(["bad.example", "", "  "])
      {:ok, domains} = BlocklistAudit.parse_list(body)

      assert MapSet.size(domains) == 1
      assert MapSet.member?(domains, "bad.example")
    end
  end

  describe "get_local_blocklist/0" do
    test "returns empty set when no blocklist configured" do
      result = BlocklistAudit.get_local_blocklist()
      assert MapSet.size(result) == 0
    end

    test "parses comma-separated blocklist from settings" do
      Repo.insert!(%Setting{key: "ap_domain_blocklist", value: "bad.example, evil.org, spam.net"})

      result = BlocklistAudit.get_local_blocklist()
      assert MapSet.size(result) == 3
      assert MapSet.member?(result, "bad.example")
      assert MapSet.member?(result, "evil.org")
      assert MapSet.member?(result, "spam.net")
    end

    test "normalizes to lowercase and trims" do
      Repo.insert!(%Setting{key: "ap_domain_blocklist", value: " Bad.Example , EVIL.ORG "})

      result = BlocklistAudit.get_local_blocklist()
      assert MapSet.member?(result, "bad.example")
      assert MapSet.member?(result, "evil.org")
    end
  end

  describe "audit/0" do
    test "returns error when no audit URL configured" do
      assert {:error, :no_audit_url} = BlocklistAudit.audit()
    end

    test "returns error when audit URL is empty string" do
      Repo.insert!(%Setting{key: "ap_blocklist_audit_url", value: ""})
      assert {:error, :no_audit_url} = BlocklistAudit.audit()
    end
  end
end
