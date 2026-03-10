defmodule Baudrate.Federation.ObjectResolverTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Federation.{HTTPClient, KeyStore, ObjectResolver, RemoteActor}
  alias Baudrate.Setup

  @remote_actor_ap_id "https://remote.example/users/alice"
  @remote_object_ap_id "https://remote.example/posts/42"

  setup do
    Setup.seed_roles_and_permissions()
    KeyStore.ensure_site_keypair()
    :ok
  end

  defp insert_remote_actor do
    {public_pem, _private_pem} = KeyStore.generate_keypair()

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: @remote_actor_ap_id,
        username: "alice",
        domain: "remote.example",
        display_name: "Alice",
        public_key_pem: public_pem,
        inbox: "https://remote.example/users/alice/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    {actor, public_pem}
  end

  defp build_actor_json(public_pem) do
    Jason.encode!(%{
      "id" => @remote_actor_ap_id,
      "type" => "Person",
      "preferredUsername" => "alice",
      "name" => "Alice",
      "inbox" => "https://remote.example/users/alice/inbox",
      "outbox" => "https://remote.example/users/alice/outbox",
      "publicKey" => %{
        "id" => "#{@remote_actor_ap_id}#main-key",
        "publicKeyPem" => public_pem
      }
    })
  end

  defp build_object_json(type, opts \\ []) do
    content = Keyword.get(opts, :content, "<p>Hello world</p>")
    sensitive = Keyword.get(opts, :sensitive, false)
    summary = Keyword.get(opts, :summary, nil)
    id = Keyword.get(opts, :id, @remote_object_ap_id)

    object = %{
      "id" => id,
      "type" => type,
      "attributedTo" => @remote_actor_ap_id,
      "content" => content,
      "published" => "2026-01-15T12:00:00Z",
      "url" => "https://remote.example/@alice/42",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["#{@remote_actor_ap_id}/followers"]
    }

    object =
      if sensitive, do: Map.put(object, "sensitive", true), else: object

    object =
      if summary, do: Map.put(object, "summary", summary), else: object

    Jason.encode!(object)
  end

  defp stub_object_and_actor(object_json, actor_json) do
    Req.Test.stub(HTTPClient, fn conn ->
      cond do
        conn.request_path == "/posts/42" ->
          Plug.Conn.send_resp(conn, 200, object_json)

        conn.request_path == "/users/alice" ->
          Plug.Conn.send_resp(conn, 200, actor_json)

        true ->
          Plug.Conn.send_resp(conn, 404, "Not Found")
      end
    end)
  end

  describe "fetch/1" do
    test "returns preview map for a valid remote Note" do
      {_actor, public_pem} = insert_remote_actor()
      object_json = build_object_json("Note")
      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:ok, preview} = ObjectResolver.fetch(@remote_object_ap_id)
      assert preview.ap_id == @remote_object_ap_id
      assert is_binary(preview.title)
      assert is_binary(preview.body)
      assert is_binary(preview.body_html)
      assert preview.url == "https://remote.example/@alice/42"
      assert preview.visibility == "public"
      assert %DateTime{} = preview.published_at
      assert %RemoteActor{} = preview.remote_actor
      assert is_map(preview.object)
    end

    test "returns preview map for a valid remote Article" do
      {_actor, public_pem} = insert_remote_actor()
      object_json = build_object_json("Article")
      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:ok, preview} = ObjectResolver.fetch(@remote_object_ap_id)
      assert preview.ap_id == @remote_object_ap_id
    end

    test "returns preview map for a valid remote Page" do
      {_actor, public_pem} = insert_remote_actor()
      object_json = build_object_json("Page")
      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:ok, preview} = ObjectResolver.fetch(@remote_object_ap_id)
      assert preview.ap_id == @remote_object_ap_id
    end

    test "returns {:ok, :existing, article} if already stored locally" do
      {actor, _public_pem} = insert_remote_actor()

      # Create an existing article with the same ap_id
      attrs = %{
        title: "Existing Article",
        body: "Already here",
        slug: "existing-article",
        ap_id: @remote_object_ap_id,
        remote_actor_id: actor.id,
        visibility: "public"
      }

      {:ok, %{article: existing}} = Content.create_remote_article(attrs, [])

      assert {:ok, :existing, article} = ObjectResolver.fetch(@remote_object_ap_id)
      assert article.id == existing.id
      assert article.ap_id == @remote_object_ap_id
    end

    test "returns error for non-https URL" do
      assert {:error, :invalid_url} = ObjectResolver.fetch("http://remote.example/posts/42")
    end

    test "returns error for local URL (non-https in test)" do
      # In test, endpoint URL is http://localhost:... so it fails https validation.
      # This verifies local URLs are rejected (via :invalid_url since test uses http://).
      local_url = BaudrateWeb.Endpoint.url() <> "/posts/42"
      assert {:error, :invalid_url} = ObjectResolver.fetch(local_url)
    end

    test "returns error for unsupported object type (Person)" do
      {_actor, public_pem} = insert_remote_actor()
      object_json = build_object_json("Person")
      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:error, {:unsupported_type, "Person"}} =
               ObjectResolver.fetch(@remote_object_ap_id)
    end

    test "returns error for missing object ID" do
      {_actor, public_pem} = insert_remote_actor()

      object_json =
        Jason.encode!(%{
          "type" => "Note",
          "attributedTo" => @remote_actor_ap_id,
          "content" => "<p>No ID here</p>"
        })

      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:error, :missing_id} = ObjectResolver.fetch(@remote_object_ap_id)
    end

    test "prepends content warning when sensitive with summary" do
      {_actor, public_pem} = insert_remote_actor()

      object_json =
        build_object_json("Note",
          content: "<p>Spoiler content</p>",
          sensitive: true,
          summary: "Spoiler Alert"
        )

      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:ok, preview} = ObjectResolver.fetch(@remote_object_ap_id)
      assert preview.body =~ "[CW: Spoiler Alert]"
      assert preview.body =~ "Spoiler content"
    end

    test "returns error when fetch fails with HTTP error" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, {:fetch_failed, _}} =
               ObjectResolver.fetch("https://remote.example/posts/broken")
    end

    test "returns error for missing author (no attributedTo)" do
      {_actor, _public_pem} = insert_remote_actor()

      object_json =
        Jason.encode!(%{
          "id" => @remote_object_ap_id,
          "type" => "Note",
          "content" => "<p>No author</p>"
        })

      Req.Test.stub(HTTPClient, fn conn ->
        if conn.request_path == "/posts/42" do
          Plug.Conn.send_resp(conn, 200, object_json)
        else
          Plug.Conn.send_resp(conn, 404, "Not Found")
        end
      end)

      assert {:error, :missing_author} = ObjectResolver.fetch(@remote_object_ap_id)
    end
  end

  describe "resolve/1" do
    test "creates a remote article for a valid remote Note" do
      {_actor, public_pem} = insert_remote_actor()
      object_json = build_object_json("Note")
      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:ok, article} = ObjectResolver.resolve(@remote_object_ap_id)
      assert article.ap_id == @remote_object_ap_id
      assert is_binary(article.title)
      assert is_binary(article.body)
      assert article.remote_actor_id != nil
      assert %RemoteActor{} = article.remote_actor
      assert article.boards == []
    end

    test "returns existing article on dedup (same ap_id)" do
      {actor, _public_pem} = insert_remote_actor()

      # Create an existing article with the same ap_id
      attrs = %{
        title: "Existing",
        body: "Already here",
        slug: "existing-dedup",
        ap_id: @remote_object_ap_id,
        remote_actor_id: actor.id,
        visibility: "public"
      }

      {:ok, %{article: existing}} = Content.create_remote_article(attrs, [])

      # resolve should return the existing article without HTTP calls
      assert {:ok, article} = ObjectResolver.resolve(@remote_object_ap_id)
      assert article.id == existing.id
      assert article.ap_id == @remote_object_ap_id
    end

    test "returns error for non-https URL" do
      assert {:error, :invalid_url} = ObjectResolver.resolve("http://remote.example/posts/42")
    end

    test "returns error for local URL (non-https in test)" do
      local_url = BaudrateWeb.Endpoint.url() <> "/posts/42"
      assert {:error, :invalid_url} = ObjectResolver.resolve(local_url)
    end

    test "returns error for unsupported object type" do
      {_actor, public_pem} = insert_remote_actor()
      object_json = build_object_json("Person")
      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:error, {:unsupported_type, "Person"}} =
               ObjectResolver.resolve(@remote_object_ap_id)
    end

    test "returns error for missing object ID" do
      {_actor, public_pem} = insert_remote_actor()

      object_json =
        Jason.encode!(%{
          "type" => "Note",
          "attributedTo" => @remote_actor_ap_id,
          "content" => "<p>No ID</p>"
        })

      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:error, :missing_id} = ObjectResolver.resolve(@remote_object_ap_id)
    end

    test "sets visibility from addressing" do
      {_actor, public_pem} = insert_remote_actor()
      object_json = build_object_json("Note")
      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:ok, article} = ObjectResolver.resolve(@remote_object_ap_id)
      assert article.visibility == "public"
    end

    test "sets forwardable based on visibility" do
      {_actor, public_pem} = insert_remote_actor()
      object_json = build_object_json("Note")
      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:ok, article} = ObjectResolver.resolve(@remote_object_ap_id)
      # Public posts should be forwardable
      assert article.forwardable == true
    end

    test "content warning is included in materialized article body" do
      {_actor, public_pem} = insert_remote_actor()

      object_json =
        build_object_json("Note",
          content: "<p>NSFW content</p>",
          sensitive: true,
          summary: "NSFW"
        )

      actor_json = build_actor_json(public_pem)
      stub_object_and_actor(object_json, actor_json)

      assert {:ok, article} = ObjectResolver.resolve(@remote_object_ap_id)
      assert article.body =~ "[CW: NSFW]"
      assert article.body =~ "NSFW content"
    end
  end
end
