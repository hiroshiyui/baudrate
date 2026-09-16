defmodule Baudrate.Federation.BlockedDomainOutboundTest do
  @moduledoc """
  A block stops us reaching out, not only listening (ADR 0030, decision 9).

  Before this, the check ran after signature verification had already fetched
  and cached the actor, and three outbound paths never consulted it at all: the
  media proxy kept fetching the domain's images, `ObjectResolver` walked reply
  chains into it, and `ActorResolver` fetched its actors on demand. We refused
  what it sent us and kept asking it for things — which discloses our readers
  to an instance we have decided not to federate with.

  These assert the refusal happens *before* any request is made. None of them
  stubs HTTP: if a refusal regressed, the test would attempt a real fetch to
  blocked.example and fail on that instead, which is still a failure.
  """
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation.{ActorResolver, DomainBlockCache, DomainBlocks, ObjectResolver}
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Setup

  @blocked "blocked.example"

  setup do
    Setup.seed_roles_and_permissions()
    Setup.set_setting("ap_federation_mode", "blocklist")
    {:ok, _} = DomainBlocks.block_domain(@blocked, nil, %{reason: "outbound test"})
    DomainBlockCache.refresh()
    :ok
  end

  describe "ActorResolver" do
    test "refuses to fetch an actor on a blocked domain" do
      assert {:error, :domain_blocked} =
               ActorResolver.resolve("https://#{@blocked}/users/alice")
    end

    test "refuses by key id too — this is the inbox's path" do
      # Signature verification resolves the actor behind `keyId`. Refusing here
      # is what stops a blocked domain getting a request from us, and what
      # keeps it from gaining a cached `remote_actors` row.
      assert {:error, :domain_blocked} =
               ActorResolver.resolve_by_key_id("https://#{@blocked}/users/alice#main-key")

      refute Repo.exists?(from ra in RemoteActor, where: ra.domain == ^@blocked)
    end

    test "still serves an actor already cached, without refetching" do
      # Blocking does not delete the row (hiding is reversible), and a cached
      # actor is still needed to render staff surfaces.
      actor = create_cached_actor()

      assert {:ok, %RemoteActor{id: id}} = ActorResolver.resolve(actor.ap_id)
      assert id == actor.id
    end

    test "a stale cached actor is not refreshed from a blocked domain" do
      actor = create_cached_actor()

      Repo.update_all(from(ra in RemoteActor, where: ra.id == ^actor.id),
        set: [fetched_at: ~U[2000-01-01 00:00:00Z]]
      )

      assert {:error, :domain_blocked} = ActorResolver.resolve(actor.ap_id)
    end
  end

  describe "ObjectResolver" do
    test "refuses to import an object from a blocked domain" do
      assert {:error, :domain_blocked} =
               ObjectResolver.resolve("https://#{@blocked}/notes/1")
    end
  end

  describe "unblocking" do
    test "lets us reach out again" do
      # The request must actually leave: a refusal that outlived the block
      # would make unblocking useless. The stub is what proves it was made.
      test_pid = self()

      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        send(test_pid, {:fetched, conn.request_path})
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      {:ok, _} = DomainBlocks.unblock_domain(@blocked)
      DomainBlockCache.refresh()

      assert {:error, reason} = ObjectResolver.resolve("https://#{@blocked}/notes/1")
      refute reason == :domain_blocked
      assert_received {:fetched, "/notes/1"}
    end
  end

  defp create_cached_actor do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://#{@blocked}/users/a#{n}",
      username: "a#{n}",
      domain: @blocked,
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://#{@blocked}/users/a#{n}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
