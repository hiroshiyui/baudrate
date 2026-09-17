defmodule Baudrate.Federation.ValidatorTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation.{DomainBlockCache, Validator}

  defp refresh_domain_cache do
    DomainBlockCache.refresh()
  end

  defp block_domains(domains) do
    Enum.each(domains, fn domain ->
      {:ok, _} = Baudrate.Federation.DomainBlocks.block_domain(domain)
    end)

    refresh_domain_cache()
  end

  describe "valid_https_url?/1" do
    test "valid HTTPS URL" do
      assert Validator.valid_https_url?("https://remote.example/users/alice")
    end

    test "rejects HTTP URL" do
      refute Validator.valid_https_url?("http://remote.example/users/alice")
    end

    test "rejects nil" do
      refute Validator.valid_https_url?(nil)
    end

    test "rejects empty string" do
      refute Validator.valid_https_url?("")
    end

    test "rejects non-string values" do
      refute Validator.valid_https_url?(123)
      refute Validator.valid_https_url?(:atom)
    end

    test "rejects HTTPS URL with no host" do
      refute Validator.valid_https_url?("https://")
    end
  end

  describe "validate_payload_size/1" do
    test "within limit returns :ok" do
      body = String.duplicate("x", 1000)
      assert :ok = Validator.validate_payload_size(body)
    end

    test "at exact limit returns :ok" do
      max = 262_144
      body = String.duplicate("x", max)
      assert :ok = Validator.validate_payload_size(body)
    end

    test "over limit returns error" do
      max = 262_144
      body = String.duplicate("x", max + 1)
      assert {:error, :payload_too_large} = Validator.validate_payload_size(body)
    end
  end

  describe "validate_content_size/1" do
    test "within limit returns :ok" do
      content = String.duplicate("x", 1000)
      assert :ok = Validator.validate_content_size(content)
    end

    test "over limit returns error" do
      max = 65_536
      content = String.duplicate("x", max + 1)
      assert {:error, :content_too_large} = Validator.validate_content_size(content)
    end

    test "nil returns :ok" do
      assert :ok = Validator.validate_content_size(nil)
    end
  end

  describe "validate_object_id/1" do
    test "valid HTTPS URL in object map" do
      object = %{"id" => "https://remote.example/objects/123", "type" => "Note"}
      assert {:ok, "https://remote.example/objects/123"} = Validator.validate_object_id(object)
    end

    test "valid HTTPS URI string" do
      assert {:ok, "https://remote.example/objects/456"} =
               Validator.validate_object_id("https://remote.example/objects/456")
    end

    test "rejects HTTP URL in object map" do
      object = %{"id" => "http://remote.example/objects/123", "type" => "Note"}
      assert {:error, :invalid_object_id} = Validator.validate_object_id(object)
    end

    test "rejects HTTP URI string" do
      assert {:error, :invalid_object_id} =
               Validator.validate_object_id("http://insecure.example/obj")
    end

    test "rejects object map without id" do
      assert {:error, :invalid_object_id} = Validator.validate_object_id(%{"type" => "Note"})
    end

    test "rejects object map with non-string id" do
      assert {:error, :invalid_object_id} = Validator.validate_object_id(%{"id" => 12_345})
    end

    test "rejects nil" do
      assert {:error, :invalid_object_id} = Validator.validate_object_id(nil)
    end

    test "rejects empty string" do
      assert {:error, :invalid_object_id} = Validator.validate_object_id("")
    end

    test "rejects empty map" do
      assert {:error, :invalid_object_id} = Validator.validate_object_id(%{})
    end

    test "rejects javascript: URI string" do
      assert {:error, :invalid_object_id} = Validator.validate_object_id("javascript:alert(1)")
    end
  end

  describe "same_host?/2" do
    test "matches hosts case-insensitively and fails closed" do
      assert Validator.same_host?("https://Remote.Example/a", "https://remote.example/b")
      refute Validator.same_host?("https://remote.example/a", "https://other.example/a")
      refute Validator.same_host?(nil, "https://remote.example/a")
      refute Validator.same_host?("not a url", "https://remote.example/a")
      refute Validator.same_host?(%{"id" => "x"}, "https://remote.example/a")
    end
  end

  describe "validate_activity/1 id length" do
    test "refuses an id longer than 2048 bytes, which no unique index could store" do
      activity = %{
        "id" => "https://remote.example/activities/" <> String.duplicate("a", 2048),
        "type" => "Like",
        "actor" => "https://remote.example/users/alice",
        "object" => "https://local.example/ap/articles/x"
      }

      assert {:error, :activity_id_too_long} = Validator.validate_activity(activity)

      ok = %{
        activity
        | "id" => "https://remote.example/activities/" <> String.duplicate("a", 1900)
      }

      assert {:ok, _} = Validator.validate_activity(ok)
    end
  end

  describe "validate_activity/1 origin binding" do
    test "rejects an activity id on a different host than the actor" do
      activity = %{
        "id" => "https://mastodon.social/users/victim/statuses/1/activity",
        "type" => "Like",
        "actor" => "https://evil.example/users/mallory",
        "object" => "https://local.example/ap/articles/x"
      }

      assert {:error, :activity_id_origin_mismatch} = Validator.validate_activity(activity)
    end
  end

  describe "validate_object_origin/2" do
    test "requires the object id to live on the signer's host" do
      actor = %{ap_id: "https://remote.example/users/alice"}

      assert :ok =
               Validator.validate_object_origin(
                 %{"id" => "https://remote.example/notes/1"},
                 actor
               )

      assert {:error, :object_origin_mismatch} =
               Validator.validate_object_origin(
                 %{"id" => "https://mastodon.social/users/victim/statuses/1"},
                 actor
               )

      assert {:error, :object_origin_mismatch} = Validator.validate_object_origin(%{}, actor)

      assert {:error, :object_id_too_long} =
               Validator.validate_object_origin(
                 %{"id" => "https://remote.example/notes/" <> String.duplicate("n", 2048)},
                 actor
               )
    end
  end

  describe "validate_activity/1" do
    test "valid activity with all required fields" do
      activity = %{
        "id" => "https://remote.example/activities/1",
        "type" => "Follow",
        "actor" => "https://remote.example/users/alice",
        "object" => "https://local.example/ap/users/bob"
      }

      assert {:ok, ^activity} = Validator.validate_activity(activity)
    end

    test "missing type returns error" do
      activity = %{
        "actor" => "https://remote.example/users/alice",
        "object" => "https://local.example/ap/users/bob"
      }

      assert {:error, :invalid_activity} = Validator.validate_activity(activity)
    end

    test "missing actor returns error" do
      activity = %{
        "type" => "Follow",
        "object" => "https://local.example/ap/users/bob"
      }

      assert {:error, :invalid_activity} = Validator.validate_activity(activity)
    end

    test "missing object returns error (non-Delete)" do
      activity = %{
        "id" => "https://remote.example/activities/3",
        "type" => "Follow",
        "actor" => "https://remote.example/users/alice"
      }

      assert {:error, :missing_object} = Validator.validate_activity(activity)
    end

    test "Delete without object is allowed" do
      activity = %{
        "id" => "https://remote.example/activities/4",
        "type" => "Delete",
        "actor" => "https://remote.example/users/alice"
      }

      assert {:ok, ^activity} = Validator.validate_activity(activity)
    end

    test "invalid actor URL returns error" do
      activity = %{
        "id" => "https://remote.example/activities/5",
        "type" => "Follow",
        "actor" => "http://remote.example/users/alice",
        "object" => "https://local.example/ap/users/bob"
      }

      assert {:error, :invalid_actor_url} = Validator.validate_activity(activity)
    end

    test "missing id returns error" do
      activity = %{
        "type" => "Follow",
        "actor" => "https://remote.example/users/alice",
        "object" => "https://local.example/ap/users/bob"
      }

      assert {:error, :missing_activity_id} = Validator.validate_activity(activity)
    end

    test "non-HTTPS id returns error" do
      activity = %{
        "id" => "http://remote.example/activities/1",
        "type" => "Follow",
        "actor" => "https://remote.example/users/alice",
        "object" => "https://local.example/ap/users/bob"
      }

      assert {:error, :missing_activity_id} = Validator.validate_activity(activity)
    end

    test "non-string id returns error" do
      activity = %{
        "id" => 12_345,
        "type" => "Follow",
        "actor" => "https://remote.example/users/alice",
        "object" => "https://local.example/ap/users/bob"
      }

      assert {:error, :missing_activity_id} = Validator.validate_activity(activity)
    end

    test "completely invalid input returns error" do
      assert {:error, :invalid_activity} = Validator.validate_activity("not a map")
      assert {:error, :invalid_activity} = Validator.validate_activity(nil)
      assert {:error, :invalid_activity} = Validator.validate_activity(%{})
    end
  end

  describe "domain_blocked?/1" do
    test "not blocked when no blocklist is set" do
      refute Validator.domain_blocked?("remote.example")
    end

    test "not blocked when domain is not in the list" do
      block_domains(["bad.example", "evil.test"])
      refute Validator.domain_blocked?("remote.example")
    end

    test "blocked when domain is in the list" do
      block_domains(["bad.example", "evil.test"])
      assert Validator.domain_blocked?("bad.example")
      assert Validator.domain_blocked?("evil.test")
    end

    test "domain blocking is case-insensitive" do
      block_domains(["Bad.Example", "EVIL.test"])
      assert Validator.domain_blocked?("bad.example")
      assert Validator.domain_blocked?("evil.test")
    end

    test "a lifted block stops blocking" do
      block_domains(["bad.example"])
      assert Validator.domain_blocked?("bad.example")

      {:ok, _} = Baudrate.Federation.DomainBlocks.unblock_domain("bad.example")
      refresh_domain_cache()

      refute Validator.domain_blocked?("bad.example")
    end
  end

  describe "local_actor?/1" do
    test "local URI returns true" do
      base = BaudrateWeb.Endpoint.url()
      assert Validator.local_actor?("#{base}/ap/users/alice")
    end

    test "remote URI returns false" do
      refute Validator.local_actor?("https://remote.example/users/alice")
    end

    test "nil returns false" do
      refute Validator.local_actor?(nil)
    end

    test "base URL without path returns false" do
      base = BaudrateWeb.Endpoint.url()
      refute Validator.local_actor?(base)
    end
  end

  describe "valid_attribution?/1" do
    test "matching actor and attributedTo returns true" do
      activity = %{
        "actor" => "https://remote.example/users/alice",
        "object" => %{
          "attributedTo" => "https://remote.example/users/alice"
        }
      }

      assert Validator.valid_attribution?(activity)
    end

    test "mismatched actor and attributedTo returns false" do
      activity = %{
        "actor" => "https://remote.example/users/alice",
        "object" => %{
          "attributedTo" => "https://remote.example/users/bob"
        }
      }

      refute Validator.valid_attribution?(activity)
    end

    test "URI object (string) always returns true" do
      activity = %{
        "actor" => "https://remote.example/users/alice",
        "object" => "https://remote.example/posts/123"
      }

      assert Validator.valid_attribution?(activity)
    end

    test "activity without object returns true" do
      assert Validator.valid_attribution?(%{"actor" => "https://remote.example/users/alice"})
    end

    test "nil returns true" do
      assert Validator.valid_attribution?(nil)
    end
  end
end
