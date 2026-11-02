defmodule Baudrate.Federation.QuotesTest do
  @moduledoc """
  Acceptance gate for [ADR 0082](../../../doc/adr/0082-federated-articles-may-be-quoted.md):
  a remote post may quote a federated local article (FEP-044f), and only a
  federated one.

  Four properties, each a way the feature could go wrong:

    * **The policy follows the outbound gate.** An article that may not
      leave carries no `interactionPolicy`, and its `QuoteRequest` is
      dropped without an answer that would confirm a private slug exists.
    * **The answer is the one Mastodon checks.** The `Accept` is signed by
      the article's author, embeds the request, and its `result` is a stamp
      whose three references equal the quoting post, the article's id and
      the author — Mastodon compares all three.
    * **A server asks only for its own posts.** A quoting post on another
      host than the signer's gets no stamp.
    * **A stamp lasts only as long as the article may be quoted**, and goes
      when its quoting post is deleted by the post's own server.
  """

  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.{DeliveryJob, InboxHandler, QuoteAuthorization, RemoteActor}
  alias Baudrate.Repo
  alias Baudrate.Setup

  @activity_json "application/activity+json"
  @as_public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Setup.seed_roles_and_permissions()
    Repo.insert!(%Setup.Setting{key: "setup_completed", value: "true"})

    author = create_user()
    board = create_board(%{ap_enabled: true})
    article = create_article(author, board)
    remote = create_remote_actor()

    %{author: author, board: board, article: article, remote: remote}
  end

  describe "the policy" do
    test "a federated article lets anyone quote it, approved automatically", ctx do
      object = Federation.article_object(ctx.article)

      assert object["interactionPolicy"] == %{
               "canQuote" => %{"automaticApproval" => [@as_public]}
             }

      terms = object["@context"] |> Enum.filter(&is_map/1) |> Enum.reduce(%{}, &Map.merge/2)
      assert terms["interactionPolicy"]["@id"] == "gts:interactionPolicy"
      assert terms["canQuote"]["@id"] == "gts:canQuote"
      assert terms["automaticApproval"]["@id"] == "gts:automaticApproval"
      assert terms["gts"] == "https://gotosocial.org/ns#"
    end

    test "an article in a board that does not federate carries no policy", ctx do
      private = create_board(%{ap_enabled: false})
      article = create_article(ctx.author, private)

      refute Map.has_key?(Federation.article_object(article), "interactionPolicy")
    end
  end

  describe "QuoteRequest" do
    test "is approved with a stamp and an Accept signed by the author", ctx do
      request = quote_request(ctx.remote, ctx.article)

      assert :ok = InboxHandler.handle(request, ctx.remote, :shared)

      stamp = Repo.one!(from(q in QuoteAuthorization, where: q.article_id == ^ctx.article.id))
      assert stamp.interacting_object_ap_id == request["instrument"]

      [job] = jobs_to(ctx.remote.inbox)
      accept = Jason.decode!(job.activity_json)
      author_uri = Federation.actor_uri(:user, ctx.author.username)

      assert accept["type"] == "Accept"
      assert accept["actor"] == author_uri
      assert job.actor_uri == author_uri
      assert accept["object"]["id"] == request["id"]
      assert accept["object"]["type"] == "QuoteRequest"
      assert accept["result"] == Federation.actor_uri(:quote_authorization, stamp.id)
      refute String.contains?(accept["result"], "#"), "a stamp is an object at a path (ADR 0050)"
    end

    test "accepts an embedded quoting post", ctx do
      request = quote_request(ctx.remote, ctx.article)
      request = %{request | "instrument" => %{"id" => request["instrument"], "type" => "Note"}}

      assert :ok = InboxHandler.handle(request, ctx.remote, :shared)
      assert Repo.aggregate(QuoteAuthorization, :count) == 1
    end

    test "a repeated request keeps the same stamp", ctx do
      request = quote_request(ctx.remote, ctx.article)
      :ok = InboxHandler.handle(request, ctx.remote, :shared)
      [first] = Repo.all(QuoteAuthorization)

      again = %{request | "id" => "https://remote.example/requests/#{System.unique_integer()}"}
      :ok = InboxHandler.handle(again, ctx.remote, :shared)

      assert [%{id: id}] = Repo.all(QuoteAuthorization)
      assert id == first.id
    end

    test "a quoting post on another host than the signer's gets nothing", ctx do
      request = %{
        quote_request(ctx.remote, ctx.article)
        | "instrument" => "https://elsewhere.example/notes/1"
      }

      assert :ok = InboxHandler.handle(request, ctx.remote, :shared)
      assert Repo.aggregate(QuoteAuthorization, :count) == 0
      assert jobs_to(ctx.remote.inbox) == []
    end

    test "an article that may not federate is dropped without an answer", ctx do
      private = create_board(%{ap_enabled: false})
      article = create_article(ctx.author, private)

      assert :ok = InboxHandler.handle(quote_request(ctx.remote, article), ctx.remote, :shared)
      assert Repo.aggregate(QuoteAuthorization, :count) == 0
      assert jobs_to(ctx.remote.inbox) == [], "a Reject would confirm the slug exists"
    end

    test "a deleted article is dropped without an answer", ctx do
      {:ok, _} = Content.soft_delete_article(ctx.article, deleted_by: ctx.author.id)

      assert :ok =
               InboxHandler.handle(quote_request(ctx.remote, ctx.article), ctx.remote, :shared)

      assert Repo.aggregate(QuoteAuthorization, :count) == 0
      assert jobs_to(ctx.remote.inbox) == []
    end

    test "an actor the author blocked is refused with a Reject", ctx do
      {:ok, _} = Baudrate.Auth.block_remote_actor(ctx.author, ctx.remote.ap_id)
      request = quote_request(ctx.remote, ctx.article)

      assert :ok = InboxHandler.handle(request, ctx.remote, :shared)
      assert Repo.aggregate(QuoteAuthorization, :count) == 0

      [job] = jobs_to(ctx.remote.inbox)
      reject = Jason.decode!(job.activity_json)
      assert reject["type"] == "Reject"
      assert reject["object"]["id"] == request["id"]
    end
  end

  describe "the stamp" do
    setup ctx do
      request = quote_request(ctx.remote, ctx.article)
      :ok = InboxHandler.handle(request, ctx.remote, :shared)
      %{stamp: Repo.one!(QuoteAuthorization), request: request}
    end

    test "names exactly what the quoting server holds", ctx do
      body = ctx.conn |> get_stamp(ctx.stamp) |> json_response(200)

      assert body["type"] == "QuoteAuthorization"
      assert body["id"] == Federation.actor_uri(:quote_authorization, ctx.stamp.id)
      assert body["attributedTo"] == Federation.actor_uri(:user, ctx.author.username)
      assert body["interactingObject"] == ctx.request["instrument"]
      assert body["interactionTarget"] == Federation.article_object(ctx.article)["id"]

      terms = body["@context"] |> Enum.filter(&is_map/1) |> Enum.reduce(%{}, &Map.merge/2)
      assert terms["QuoteAuthorization"] == "https://w3id.org/fep/044f#QuoteAuthorization"
      assert terms["interactingObject"]["@id"] == "gts:interactingObject"
      assert terms["interactionTarget"]["@id"] == "gts:interactionTarget"
    end

    test "is withdrawn with the article", ctx do
      {:ok, _} = Content.soft_delete_article(ctx.article, deleted_by: ctx.author.id)
      assert ctx.conn |> get_stamp(ctx.stamp) |> response(404)
    end

    test "is withdrawn when the board stops federating", ctx do
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [ap_enabled: false])
      assert ctx.conn |> get_stamp(ctx.stamp) |> response(404)
    end

    test "is not served for an actor whose domain is blocked", ctx do
      {:ok, _} = Federation.DomainBlocks.block_domain("remote.example")
      assert ctx.conn |> get_stamp(ctx.stamp) |> response(404)
    end

    test "an unknown or out-of-range id is 404", %{conn: conn} do
      for id <- ["0", "999999999", "99999999999999999999999", "abc"] do
        conn =
          conn
          |> put_req_header("accept", @activity_json)
          |> get("/ap/quote_authorizations/#{id}")

        assert response(conn, 404)
      end
    end

    test "goes when the quoting post's own server deletes it", ctx do
      delete = %{
        "id" => "https://remote.example/deletes/#{System.unique_integer([:positive])}",
        "type" => "Delete",
        "actor" => ctx.remote.ap_id,
        "object" => ctx.request["instrument"]
      }

      assert :ok = InboxHandler.handle(delete, ctx.remote, :shared)
      assert Repo.aggregate(QuoteAuthorization, :count) == 0
    end

    test "stays when another server claims to delete the quoting post", ctx do
      other = create_remote_actor("other.example")

      delete = %{
        "id" => "https://other.example/deletes/#{System.unique_integer([:positive])}",
        "type" => "Delete",
        "actor" => other.ap_id,
        "object" => ctx.request["instrument"]
      }

      InboxHandler.handle(delete, other, :shared)
      assert Repo.aggregate(QuoteAuthorization, :count) == 1
    end
  end

  # --- Helpers ---

  defp quote_request(remote, article) do
    n = System.unique_integer([:positive])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://remote.example/requests/#{n}",
      "type" => "QuoteRequest",
      "actor" => remote.ap_id,
      "object" => Federation.actor_uri(:article, article.slug),
      "instrument" => "https://remote.example/notes/#{n}"
    }
  end

  defp get_stamp(conn, stamp) do
    conn
    |> put_req_header("accept", @activity_json)
    |> get("/ap/quote_authorizations/#{stamp.id}")
  end

  defp jobs_to(inbox), do: Repo.all(from(j in DeliveryJob, where: j.inbox_url == ^inbox))

  defp create_board(attrs) do
    %Board{}
    |> Board.changeset(
      Map.merge(%{name: "Board", slug: "quote-#{System.unique_integer([:positive])}"}, attrs)
    )
    |> Repo.insert!()
  end

  defp create_article(user, board) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Quotable",
          body: "Body",
          slug: "quote-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end

  defp create_user do
    role = Repo.one!(from r in Setup.Role, where: r.name == "user")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "quote#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_remote_actor(domain \\ "remote.example") do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://#{domain}/users/a#{n}",
      username: "a#{n}",
      domain: domain,
      public_key_pem: elem(Baudrate.Federation.KeyStore.generate_keypair(), 0),
      inbox: "https://#{domain}/users/a#{n}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
