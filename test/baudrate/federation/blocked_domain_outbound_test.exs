defmodule Baudrate.Federation.BlockedDomainOutboundTest do
  @moduledoc """
  A block stops us reaching out, not only listening (ADR 0030, decision 9).

  Before this, the check ran after signature verification had already fetched
  and cached the actor, and three outbound paths never consulted it at all: the
  media proxy kept fetching the domain's images, `ObjectResolver` walked reply
  chains into it, and `ActorResolver` fetched its actors on demand. We refused
  what it sent us and kept asking it for things — which discloses our readers
  to an instance we have decided not to federate with.

  These assert the refusal happens *before* any request is made. The
  first-hop cases stub no HTTP at all: if a refusal regressed, the test would
  attempt a real fetch to blocked.example and fail on that instead, which is
  still a failure. The redirect-hop and Announce cases do stub it, because
  there the point is which host the request reaches — a block that only ever
  saw the first URL was escaped by standing up an unblocked host that 302s to
  the blocked one, or by announcing an object URI on it.
  """
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{ActorResolver, DomainBlockCache, DomainBlocks, ObjectResolver}
  alias Baudrate.Federation.{HTTPClient, InboxHandler, KeyStore, RemoteActor}
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

  describe "InboxHandler Announce" do
    # A followed actor on an allowed domain may Announce any URI it likes, so
    # without a check the sender chose which host we signed a request to —
    # this was the last outbound fetch with neither the pre-check nor
    # `refuse_blocked:`.
    setup do
      {:ok, _} = KeyStore.ensure_site_keypair()

      test_pid = self()

      Req.Test.stub(HTTPClient, fn conn ->
        send(test_pid, {:fetched, req_host(conn), conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "type" => "Note",
            "id" => "https://#{req_host(conn)}#{conn.request_path}",
            "content" => "<p>Boosted content</p>",
            "to" => ["https://www.w3.org/ns/activitystreams#Public"],
            "published" => DateTime.to_iso8601(DateTime.utc_now())
          })
        )
      end)

      booster = followed_booster()
      {:ok, booster: booster}
    end

    test "never fetches an announced object on a blocked domain", %{booster: booster} do
      uid = System.unique_integer([:positive])
      announce_ap_id = "https://remote.example/activities/announce-#{uid}"

      activity = %{
        "id" => announce_ap_id,
        "type" => "Announce",
        "actor" => booster.ap_id,
        "object" => "https://#{@blocked}/notes/#{uid}"
      }

      assert :ok = InboxHandler.handle(activity, booster, :shared)

      refute_received {:fetched, @blocked, _},
                      "a block stops us reaching out (ADR 0030 decision 9)"

      assert Federation.get_timeline_item_by_ap_id(announce_ap_id) == nil,
             "no content may be created from a domain we refuse to talk to"
    end

    test "still fetches an announced object on an allowed domain", %{booster: booster} do
      # The control: the refusal must be about the domain, not about the path
      # being broken.
      uid = System.unique_integer([:positive])
      announce_ap_id = "https://remote.example/activities/announce-ok-#{uid}"

      activity = %{
        "id" => announce_ap_id,
        "type" => "Announce",
        "actor" => booster.ap_id,
        "object" => "https://remote.example/notes/#{uid}"
      }

      assert :ok = InboxHandler.handle(activity, booster, :shared)

      assert_received {:fetched, "remote.example", _}
      assert Federation.get_timeline_item_by_ap_id(announce_ap_id) != nil
    end
  end

  describe "HTTPClient redirect hops" do
    # Every caller that checks a domain block only ever saw the *first* URL, so
    # its operator had only to stand up an unblocked host that 302s to it.
    setup do
      test_pid = self()
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(HTTPClient, fn conn ->
        send(test_pid, {:fetched, req_host(conn), conn.request_path})
        call = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if call == 0 do
          conn
          |> Plug.Conn.put_resp_header("location", "https://#{@blocked}/users/alice")
          |> Plug.Conn.send_resp(302, "")
        else
          Plug.Conn.send_resp(conn, 200, ~s({"type":"Person"}))
        end
      end)

      :ok
    end

    test "refuses a redirect into a blocked domain when the caller opts in" do
      assert {:error, :domain_blocked} =
               HTTPClient.get("https://allowed.example/users/alice", refuse_blocked: true)

      assert_received {:fetched, "allowed.example", "/users/alice"}
      refute_received {:fetched, @blocked, _}
    end

    test "follows the same redirect when the caller does not opt in" do
      # Deliberately opt-in: in allowlist mode `domain_blocked?/1` answers
      # true for every domain that is not on the list, which must not refuse
      # an ordinary link-preview fetch.
      assert {:ok, %{status: 200}} = HTTPClient.get("https://allowed.example/users/alice")

      assert_received {:fetched, "allowed.example", "/users/alice"}
      assert_received {:fetched, @blocked, "/users/alice"}
    end

    test "the signed retry refuses it too — this is ActorResolver's path" do
      # An authorized-fetch peer answers the unsigned GET with 401, and the
      # signed retry is a second, separate call to the transport: without
      # `refuse_blocked: true` there, the redirect was followed with our site
      # key's signature attached.
      {:ok, _} = KeyStore.ensure_site_keypair()
      test_pid = self()
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(HTTPClient, fn conn ->
        send(test_pid, {:fetched, req_host(conn), conn.request_path})

        case Agent.get_and_update(agent, fn n -> {n, n + 1} end) do
          0 ->
            Plug.Conn.send_resp(conn, 401, "Unauthorized")

          1 ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://#{@blocked}/users/alice")
            |> Plug.Conn.send_resp(302, "")

          _ ->
            Plug.Conn.send_resp(conn, 200, ~s({"id":"https://#{@blocked}/users/alice"}))
        end
      end)

      assert {:error, _reason} = ActorResolver.resolve("https://allowed.example/users/alice")

      refute_received {:fetched, @blocked, _}
      refute Repo.exists?(from(ra in RemoteActor, where: ra.domain == ^@blocked))
    end
  end

  # The connection is pinned to the resolved IP, so `conn.host` is the address.
  # The `Host` header is the hostname the request was actually addressed to,
  # which is what the block is about.
  defp req_host(conn) do
    conn |> Plug.Conn.get_req_header("host") |> List.first()
  end

  defp followed_booster do
    import Ecto.Query

    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "outb_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    n = System.unique_integer([:positive])

    booster =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/booster-#{n}",
        username: "booster_#{n}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/users/booster-#{n}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    {:ok, follow} = Federation.create_user_follow(user, booster)
    {:ok, _} = Federation.accept_user_follow(follow.ap_id)

    booster
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
