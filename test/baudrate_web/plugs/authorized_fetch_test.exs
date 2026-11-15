defmodule BaudrateWeb.Plugs.AuthorizedFetchTest do
  use BaudrateWeb.ConnCase, async: false

  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  describe "authorized fetch plug" do
    test "passes through when setting is disabled", %{conn: conn} do
      Setup.set_setting("ap_authorized_fetch", "false")

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/ap/site")

      refute conn.halted
      assert conn.status in [200, 404]
    end

    test "returns 401 when enabled and no signature provided", %{conn: conn} do
      Setup.set_setting("ap_authorized_fetch", "true")

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/ap/site")

      assert conn.status == 401
    end

    test "allows WebFinger even when authorized fetch is enabled", %{conn: conn} do
      Setup.set_setting("ap_authorized_fetch", "true")

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/webfinger?resource=acct:nonexistent@localhost")

      # Should not be 401 — might be 404 or 400 but not blocked by auth
      refute conn.status == 401
    end

    test "allows NodeInfo even when authorized fetch is enabled", %{conn: conn} do
      Setup.set_setting("ap_authorized_fetch", "true")

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/nodeinfo")

      refute conn.status == 401
    end
  end

  # A valid signature is not enough: the signer must be one the inbox would
  # admit. The resolver returns a cached actor without asking about blocks,
  # so a server blocked after we cached one of its actors kept being served.
  describe "a signed GET from a blocked or suspended actor" do
    alias Baudrate.Federation.{DomainBlocks, HTTPSignature, KeyStore, RemoteActor, RemoteActors}

    setup do
      Setup.set_setting("ap_authorized_fetch", "true")
      {public_pem, private_pem} = KeyStore.generate_keypair()
      uid = System.unique_integer([:positive])
      ap_id = "https://fetcher-#{uid}.example/users/bot"

      {:ok, actor} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: ap_id,
          username: "bot",
          domain: "fetcher-#{uid}.example",
          public_key_pem: public_pem,
          inbox: "#{ap_id}/inbox",
          actor_type: "Application",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Baudrate.Repo.insert()

      {:ok, actor: actor, private_pem: private_pem}
    end

    defp signed_get(actor, private_pem) do
      headers =
        HTTPSignature.sign_get(
          "https://local.example/ap/site",
          private_pem,
          actor.ap_id <> "#main-key"
        )

      Plug.Test.conn(:get, "/ap/site")
      |> Map.put(:req_headers, [
        {"host", "local.example"},
        {"date", headers["date"]},
        {"signature", headers["signature"]}
      ])
      |> BaudrateWeb.Plugs.AuthorizedFetch.call([])
    end

    test "an admitted actor passes", %{actor: actor, private_pem: private_pem} do
      conn = signed_get(actor, private_pem)
      refute conn.halted
      assert conn.assigns.remote_actor.id == actor.id
    end

    test "is refused once its domain is blocked", %{actor: actor, private_pem: private_pem} do
      {:ok, _} = DomainBlocks.block_domain(actor.domain)

      conn = signed_get(actor, private_pem)
      assert conn.halted
      assert conn.status == 401
    end

    test "is refused once the actor is suspended", %{actor: actor, private_pem: private_pem} do
      {:ok, _} = RemoteActors.suspend(actor, nil, "test")

      conn = signed_get(actor, private_pem)
      assert conn.halted
      assert conn.status == 401
    end
  end
end
