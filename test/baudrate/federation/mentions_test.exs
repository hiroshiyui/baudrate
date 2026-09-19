defmodule Baudrate.Federation.MentionsTest do
  @moduledoc """
  Acceptance gate for [ADR 0051](../../../doc/adr/0051-a-mention-addresses-and-the-board-gate-still-decides.md):
  a reply threads where it belongs, a mention reaches the person it names, and
  neither one widens who may read the post.

  The third is the one to be careful about, and it is why this file exists
  rather than a few assertions in `publisher_test.exs`. A mention is the only
  place where a **member** picks an outbound recipient by typing. ADR 0043
  made the board the sole answer to "may this content leave", at five
  surfaces; a mention is a sixth, and if it were an *exception* rather than a
  surface, then one handle in one post would send a staff-only article, in
  full, to any instance on the internet. So the gate is checked in all three
  places it has to hold — the tag, the addressing, and the delivery job — plus
  the one that is easy to forget: the **lookup**, which is itself an outbound
  request that tells a server somebody here typed that handle.

  **What this does not check.** `Mentions.extract/1` folds a handle naming
  *this* instance's own host into the local list, so `@alice@our.host` is the
  long form of `@alice` rather than an actor to resolve over the network. The
  test endpoint's host is `localhost`, a single label with no dot, so no
  handle on it is a handle at all here and the rule cannot be exercised. It is
  stated in the module's own documentation instead.

  **Add a new mention surface here.**
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.{Board, Markdown}
  alias Baudrate.Federation
  alias Baudrate.Federation.{DomainBlockCache, DomainBlocks, HTTPClient}
  alias Baudrate.Federation.{ObjectBuilder, Publisher, RemoteActor}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    Setup.set_setting("ap_federation_mode", "blocklist")
    DomainBlockCache.refresh()

    # Every test runs with the transport stubbed: a handle that does not
    # resolve is an ordinary case here, and an unstubbed one would reach the
    # real network.
    stub_404()

    open = create_board(ap_enabled: true)
    closed = create_board(ap_enabled: false)
    author = create_user()
    known = create_remote_actor("known", "friendly.example")

    %{open: open, closed: closed, author: author, known: known}
  end

  describe "a handle names a person, not a local lookalike" do
    test "a remote handle is not read as a local mention", ctx do
      # The bug this closes: `@known@friendly.example` matched the local
      # pattern at `@known` — `@` counts as a non-word character — and
      # linkified to `/users/known`, pointing a mention of a remote person at
      # whoever holds that name here.
      _decoy = create_user(username: "known")

      assert Markdown.extract_mentions("hi @known@friendly.example") == []

      assert Markdown.extract_remote_mentions("hi @known@friendly.example") ==
               [{"known", "friendly.example"}]

      html = Markdown.to_html("hi @known@friendly.example")
      refute html =~ ~s[href="/users/known"]
      assert html =~ "mention-remote"
      assert ctx.author
    end

    test "a bare handle is still a local mention" do
      assert Markdown.extract_mentions("hi @alice") == ["alice"]
      assert Markdown.to_html("hi @alice") =~ ~s[href="/users/alice"]
    end

    test "an email address is left alone" do
      assert Markdown.extract_remote_mentions("write to bob@example.com") == []
      assert Markdown.to_html("write to bob@example.com") =~ "mailto:bob@example.com"
    end
  end

  describe "threading (ADR 0051 decision 1)" do
    test "a top-level comment replies to the article", ctx do
      {:ok, %{article: article}} = create_article(ctx.author, ctx.open)
      {:ok, comment} = create_comment(article, ctx.author)

      {activity, _} = Publisher.build_create_comment(comment, article)
      assert activity["object"]["inReplyTo"] == article.ap_id
    end

    test "a reply replies to its parent comment, by that comment's own URI", ctx do
      {:ok, %{article: article}} = create_article(ctx.author, ctx.open)
      {:ok, parent} = create_comment(article, ctx.author)
      {:ok, reply} = create_comment(article, ctx.author, parent)

      {activity, _} = Publisher.build_create_comment(reply, article)

      assert activity["object"]["inReplyTo"] == parent.ap_id
      refute activity["object"]["inReplyTo"] == article.ap_id

      # The served object and the published one agree.
      assert ObjectBuilder.comment_object(reply)["inReplyTo"] == parent.ap_id
    end

    test "a reply to a remote comment names the remote URI, so it threads upstream", ctx do
      {:ok, %{article: article}} = create_article(ctx.author, ctx.open)
      remote_uri = "https://friendly.example/notes/#{System.unique_integer([:positive])}"

      {:ok, parent} =
        Content.create_remote_comment(%{
          body: "from elsewhere",
          body_html: "<p>from elsewhere</p>",
          ap_id: remote_uri,
          article_id: article.id,
          remote_actor_id: ctx.known.id
        })

      {:ok, reply} = create_comment(article, ctx.author, parent)

      {activity, _} = Publisher.build_create_comment(reply, article)
      assert activity["object"]["inReplyTo"] == remote_uri
    end
  end

  describe "a known actor is tagged and addressed" do
    test "the article object carries the Mention tag and the cc", ctx do
      {:ok, %{article: article}} = create_article(ctx.author, ctx.open, body: mention(ctx.known))

      object = Federation.article_object(article)

      assert %{"type" => "Mention", "href" => href, "name" => name} =
               Enum.find(object["tag"], &(&1["type"] == "Mention"))

      assert href == ctx.known.ap_id
      assert name == "@known@friendly.example"
      assert ctx.known.ap_id in object["cc"]
    end

    test "the Create activity addresses them too", ctx do
      {:ok, %{article: article}} = create_article(ctx.author, ctx.open, body: mention(ctx.known))

      {activity, _} = Publisher.build_create_article(article)

      # `article_addressing/2` overwrites the object's `cc`, so if only the
      # object builder knew about mentions this is where it would be lost.
      assert ctx.known.ap_id in activity["cc"]
      assert ctx.known.ap_id in activity["object"]["cc"]
    end

    test "a comment carries them as well", ctx do
      {:ok, %{article: article}} = create_article(ctx.author, ctx.open)
      {:ok, comment} = create_comment(article, ctx.author, nil, mention(ctx.known))

      {activity, _} = Publisher.build_create_comment(comment, article)

      assert ctx.known.ap_id in activity["object"]["cc"]
      assert Enum.any?(activity["object"]["tag"], &(&1["href"] == ctx.known.ap_id))
    end

    test "an unknown handle leaves no tag and no error", ctx do
      body = "hello @nobody@unreachable.example"
      {:ok, %{article: article}} = create_article(ctx.author, ctx.open, body: body)

      object = Federation.article_object(article)
      refute Enum.any?(object["tag"] || [], &(&1["type"] == "Mention"))
    end

    test "an actor on a blocked domain is never addressed", ctx do
      {:ok, _} = DomainBlocks.block_domain("friendly.example", nil, %{reason: "test"})
      DomainBlockCache.refresh()

      {:ok, %{article: article}} = create_article(ctx.author, ctx.open, body: mention(ctx.known))

      object = Federation.article_object(article)

      refute Enum.any?(object["tag"] || [], &(&1["type"] == "Mention"))
      refute ctx.known.ap_id in object["cc"]
    end
  end

  describe "the board gate still decides (P3-D3)" do
    test "a non-federated board produces no tag and no cc", ctx do
      {:ok, %{article: article}} =
        create_article(ctx.author, ctx.closed, body: mention(ctx.known))

      object = Federation.article_object(article)

      refute Enum.any?(object["tag"] || [], &(&1["type"] == "Mention")),
             "a Mention tag on an article that may not leave names the recipient " <>
               "in an object three unauthenticated endpoints serve"

      refute ctx.known.ap_id in object["cc"]

      {activity, _} = Publisher.build_create_article(article)
      refute ctx.known.ap_id in activity["cc"]
    end

    test "a non-federated board enqueues no delivery to the mentioned actor", ctx do
      {:ok, %{article: article}} =
        create_article(ctx.author, ctx.closed, body: mention(ctx.known))

      Repo.delete_all(Baudrate.Federation.DeliveryJob)
      Publisher.publish_article_created(Repo.preload(article, [:boards, :user]))

      assert inbox_urls() == [],
             "typing a handle must not be a way to send a private board's article " <>
               "to an arbitrary instance (ADR 0043, ADR 0051 decision 3)"
    end

    test "a federated board does deliver to the mentioned actor", ctx do
      {:ok, %{article: article}} = create_article(ctx.author, ctx.open, body: mention(ctx.known))

      Repo.delete_all(Baudrate.Federation.DeliveryJob)
      Publisher.publish_article_created(Repo.preload(article, [:boards, :user]))

      assert ctx.known.inbox in inbox_urls()
    end

    test "a non-federated board makes no outbound lookup at all", ctx do
      me = self()

      watch_fetches(me)

      {:ok, _} =
        create_article(ctx.author, ctx.closed, body: "hi @stranger@unreachable.example")

      # Resolving a handle is itself an outbound request. Making it for content
      # that can never leave tells that server a member here typed the handle —
      # a smaller leak than delivering the article, governed by the same
      # decision.
      refute_received {:fetched, _}
    end

    test "a federated board does look the handle up", ctx do
      me = self()

      watch_fetches(me)

      {:ok, _} = create_article(ctx.author, ctx.open, body: "hi @stranger@unreachable.example")

      assert_received {:fetched, "unreachable.example"}
    end
  end

  describe "the lookup is bounded" do
    test "a throttled user resolves nothing, and the post still succeeds", ctx do
      me = self()

      watch_fetches(me)

      BaudrateWeb.RateLimiter.Sandbox.set_global_response({:deny, 60_000})

      assert {:ok, _} =
               create_article(ctx.author, ctx.open, body: "hi @stranger@unreachable.example")

      refute_received {:fetched, _}
    after
      BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})
    end

    test "an already-known handle needs no lookup", ctx do
      me = self()

      watch_fetches(me)

      {:ok, _} = create_article(ctx.author, ctx.open, body: mention(ctx.known))

      refute_received {:fetched, _}
    end
  end

  # --- helpers ---

  defp mention(actor), do: "hello @#{actor.username}@#{actor.domain}, look at this"

  defp stub_404 do
    Req.Test.stub(HTTPClient, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
  end

  # Reports the `Host` header rather than `conn.host`: `HTTPClient` resolves
  # DNS once and connects to the address, carrying the name in the header, so
  # `conn.host` is always the pinned IP.
  defp watch_fetches(pid) do
    Req.Test.stub(HTTPClient, fn conn ->
      send(pid, {:fetched, conn |> Plug.Conn.get_req_header("host") |> List.first()})
      Plug.Conn.send_resp(conn, 404, "")
    end)
  end

  defp inbox_urls do
    Baudrate.Federation.DeliveryJob |> Repo.all() |> Enum.map(& &1.inbox_url) |> Enum.uniq()
  end

  defp create_board(opts) do
    %Board{}
    |> Board.changeset(%{
      name: "Board",
      slug: "men-#{System.unique_integer([:positive])}",
      ap_enabled: Keyword.fetch!(opts, :ap_enabled)
    })
    |> Repo.insert!()
  end

  defp create_user(opts \\ []) do
    role = Repo.one!(from r in Setup.Role, where: r.name == "user")
    username = Keyword.get(opts, :username, "men#{System.unique_integer([:positive])}")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => username,
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_article(user, board, opts \\ []) do
    Content.create_article(
      %{
        title: "An article",
        body: Keyword.get(opts, :body, "plain body"),
        slug: "men-art-#{System.unique_integer([:positive])}",
        user_id: user.id
      },
      [board.id]
    )
  end

  defp create_comment(article, user, parent \\ nil, body \\ "a comment") do
    Content.create_comment(%{
      "body" => body,
      "article_id" => article.id,
      "user_id" => user.id,
      "parent_id" => parent && parent.id
    })
  end

  defp create_remote_actor(username, domain) do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://#{domain}/users/#{username}/inbox-#{n}",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
