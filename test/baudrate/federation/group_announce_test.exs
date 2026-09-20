defmodule Baudrate.Federation.GroupAnnounceTest do
  @moduledoc """
  Acceptance gate for [ADR 0053](../../../doc/adr/0053-a-group-announce-is-a-carrier.md):
  a Lemmy community's `Announce` is a **carrier**, and the activity it carries
  is checked as if it had arrived on its own.

  A Lemmy community is a hub rather than a booster — members send activities
  *to* it and it announces them to every subscriber — so its `Announce` wraps
  an **activity** where a Mastodon boost wraps an object. Every one of them
  was dropped.

  The whole security question is **who may speak for the inner actor**, and it
  is the reason most of this file is refusals. The signature on the outer
  Announce is the group's; the inner activity carries none. So a community
  that could have its relayed activities honoured unconditionally could mint a
  `Delete`, a `Like` or a `Create` for any actor on any host — which is
  exactly what ADR 0046 exists to refuse. The rule is that the group may speak
  for its own host and no further.

  **Add a carried activity type here**, with its refusals, not just its happy
  path.
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.{DomainBlockCache, DomainBlocks, InboxHandler}
  alias Baudrate.Federation.{RemoteActor, RemoteActors}
  alias Baudrate.Setup

  @community_host "lemmy.example"
  @other_host "elsewhere.example"

  setup do
    Setup.seed_roles_and_permissions()
    Setup.set_setting("ap_federation_mode", "blocklist")
    DomainBlockCache.refresh()

    board = create_board()
    community = create_actor(@community_host, "tech", "Group")
    member = create_actor(@community_host, "alice")
    outsider = create_actor(@other_host, "bob")

    {:ok, follow} = Federation.create_board_follow(board, community)
    {:ok, _} = Federation.accept_board_follow(follow.ap_id)

    %{board: board, community: community, member: member, outsider: outsider}
  end

  describe "a community relays its own instance's activities" do
    test "Announce(Create(Page)) becomes an article in the following board", ctx do
      activity = announce(ctx.community, create_page(ctx.member, "Hello from Lemmy"))

      assert :ok = InboxHandler.handle(activity, ctx.community, :shared)

      article = Content.get_article_by_ap_id(activity["object"]["object"]["id"])
      assert article
      assert article.title == "Hello from Lemmy"
      assert article.remote_actor_id == ctx.member.id
    end

    test "the relayed activity is attributed to its own actor, not the group", ctx do
      activity = announce(ctx.community, create_page(ctx.member, "By alice"))

      assert :ok = InboxHandler.handle(activity, ctx.community, :shared)

      article = Content.get_article_by_ap_id(activity["object"]["object"]["id"])
      refute article.remote_actor_id == ctx.community.id
    end

    test "a relay is not recorded as a boost", ctx do
      activity = announce(ctx.community, create_page(ctx.member, "Not a boost"))

      assert :ok = InboxHandler.handle(activity, ctx.community, :shared)

      # A community is a hub, not a booster. Recording an `announces` row here
      # would show every post in a followed community as somebody's boost.
      assert Repo.aggregate(Federation.Announce, :count, :id) == 0
    end

    test "processing twice is harmless, because it happens", ctx do
      activity = announce(ctx.community, create_page(ctx.member, "Twice"))

      assert :ok = InboxHandler.handle(activity, ctx.community, :shared)
      assert :ok = InboxHandler.handle(activity, ctx.community, :shared)

      ap_id = activity["object"]["object"]["id"]

      assert Repo.aggregate(from(a in Content.Article, where: a.ap_id == ^ap_id), :count, :id) ==
               1
    end
  end

  describe "a community may not speak for another host" do
    test "a relayed Delete from a foreign actor leaves the post standing", ctx do
      # A real article by that actor, so "nothing happened" is a claim about
      # this row rather than about an empty table.
      article = remote_article(ctx.outsider, ctx.board)

      inner = %{
        "id" => "https://#{@other_host}/activities/delete-1",
        "type" => "Delete",
        "actor" => ctx.outsider.ap_id,
        "object" => article.ap_id
      }

      assert :ok = InboxHandler.handle(announce(ctx.community, inner), ctx.community, :shared)

      # Nothing to verify against, so nothing is honoured: otherwise any
      # community could delete any actor's content anywhere.
      assert Repo.get!(Content.Article, article.id).deleted_at == nil
    end

    test "a relayed Like from a foreign actor is dropped", ctx do
      user = create_user()
      article = local_article(user, ctx.board)

      inner = %{
        "id" => "https://#{@other_host}/activities/like-1",
        "type" => "Like",
        "actor" => ctx.outsider.ap_id,
        "object" => article.ap_id
      }

      assert :ok = InboxHandler.handle(announce(ctx.community, inner), ctx.community, :shared)
      assert Content.count_article_likes(article) == 0
    end

    test "a relayed Create from a foreign actor falls back to the content path", ctx do
      # Not honoured *as an activity* — but the object it names has an origin
      # of its own, so the ordinary announced-content path still applies, with
      # its attribution binding. The post arrives, verified by the host that
      # can prove it.
      page = page_object(ctx.outsider, "Cross-posted")

      inner = %{
        "id" => "https://#{@other_host}/activities/create-x",
        "type" => "Create",
        "actor" => ctx.outsider.ap_id,
        "object" => page
      }

      assert :ok = InboxHandler.handle(announce(ctx.community, inner), ctx.community, :shared)

      article = Content.get_article_by_ap_id(page["id"])
      assert article
      assert article.remote_actor_id == ctx.outsider.id
    end

    test "a foreign Create whose object is attributed to a third host is refused", ctx do
      # The object claims to be by somebody on a host that is neither the
      # group's nor the object's own — the impersonation ADR 0046 refuses.
      page =
        ctx.outsider
        |> page_object("Forged")
        |> Map.put("attributedTo", "https://victim.example/u/carol")

      inner = %{
        "id" => "https://#{@other_host}/activities/create-forged",
        "type" => "Create",
        "actor" => ctx.outsider.ap_id,
        "object" => page
      }

      assert :ok = InboxHandler.handle(announce(ctx.community, inner), ctx.community, :shared)
      refute Content.get_article_by_ap_id(page["id"])
    end
  end

  describe "a recorded Lemmy payload" do
    # Hand-built maps agree with whatever the test author imagined. This is
    # the shape Lemmy actually sends — `audience`, a `source` alongside
    # `content`, a `language` object, the community in `cc` — so a field it
    # relies on going missing shows up here rather than in production.
    test "Announce(Create(Page)) from a community lands in the following board", ctx do
      activity = lemmy_fixture("lemmy_announce_create_page.json")

      # The fixture names fixed URIs; give them the actors they describe.
      community = create_actor_at("https://lemmy.example/c/tech", "tech", "Group")
      author = create_actor_at("https://lemmy.example/u/alice", "alice")

      {:ok, follow} = Federation.create_board_follow(ctx.board, community)
      {:ok, _} = Federation.accept_board_follow(follow.ap_id)

      assert :ok = InboxHandler.handle(activity, community, :shared)

      article = Content.get_article_by_ap_id("https://lemmy.example/post/4242")
      assert article
      assert article.title == "A packet radio primer"
      assert article.remote_actor_id == author.id
      assert article.body =~ "AX.25"

      board_ids = article |> Repo.preload(:boards) |> Map.fetch!(:boards) |> Enum.map(& &1.id)
      assert ctx.board.id in board_ids
    end
  end

  describe "the other direction: a Lemmy user follows one of our boards" do
    test "the Follow is accepted and the board gains a follower", ctx do
      subscriber = create_actor_at("https://lemmy.example/u/bob", "bob")
      board_uri = Federation.actor_uri(:board, ctx.board.slug)

      # Lemmy addresses the Follow to the community actor and names it as the
      # object, which is what `resolve_target_uri/2` reads at a shared inbox.
      follow = %{
        "id" => "https://lemmy.example/activities/follow/0000-0001",
        "type" => "Follow",
        "actor" => subscriber.ap_id,
        "object" => board_uri,
        "to" => [board_uri]
      }

      Repo.delete_all(Federation.DeliveryJob)

      assert :ok = InboxHandler.handle(follow, subscriber, :shared)

      assert Federation.follower_exists?(board_uri, subscriber.ap_id)

      accept =
        Federation.DeliveryJob
        |> Repo.all()
        |> Enum.map(&Jason.decode!(&1.activity_json))
        |> Enum.find(&(&1["type"] == "Accept"))

      assert accept, "a Follow this instance honours has to be answered, or the subscriber waits"
      assert accept["actor"] == board_uri
    end
  end

  describe "a same-host activity is honoured, with its own actor" do
    test "a relayed Like registers against the local article", ctx do
      user = create_user()
      article = local_article(user, ctx.board)

      inner = %{
        "id" =>
          "https://#{@community_host}/activities/like-#{System.unique_integer([:positive])}",
        "type" => "Like",
        "actor" => ctx.member.ap_id,
        "object" => article.ap_id
      }

      assert :ok = InboxHandler.handle(announce(ctx.community, inner), ctx.community, :shared)
      assert Content.count_article_likes(article) == 1
    end

    test "a relayed Delete withdraws that actor's own post", ctx do
      article = remote_article(ctx.member, ctx.board)

      inner = %{
        "id" =>
          "https://#{@community_host}/activities/delete-#{System.unique_integer([:positive])}",
        "type" => "Delete",
        "actor" => ctx.member.ap_id,
        "object" => article.ap_id
      }

      assert :ok = InboxHandler.handle(announce(ctx.community, inner), ctx.community, :shared)
      assert Repo.get!(Content.Article, article.id).deleted_at
    end
  end

  describe "the carried activity faces every other check" do
    test "an inner activity whose id is on another host is refused", ctx do
      inner =
        ctx.member
        |> create_page("Mismatched")
        |> Map.put("id", "https://#{@other_host}/activities/create-1")

      assert :ok = InboxHandler.handle(announce(ctx.community, inner), ctx.community, :shared)
      refute Content.get_article_by_ap_id(inner["object"]["id"])
    end

    test "an inner activity claiming a local actor is refused", ctx do
      user = create_user()

      inner =
        ctx.member
        |> create_page("Impersonation")
        |> Map.put("actor", Federation.actor_uri(:user, user.username))

      assert :ok = InboxHandler.handle(announce(ctx.community, inner), ctx.community, :shared)
      refute Content.get_article_by_ap_id(inner["object"]["id"])
    end

    test "a suspended inner actor is refused even though the group is fine", ctx do
      {:ok, _} = RemoteActors.suspend(ctx.member, nil, "acceptance test")

      inner = create_page(ctx.member, "From a suspended account")

      assert :ok =
               InboxHandler.handle(announce(ctx.community, inner), ctx.community, :shared)

      refute Content.get_article_by_ap_id(inner["object"]["id"])
    end

    test "a blocked inner domain is refused", ctx do
      {:ok, _} = DomainBlocks.block_domain(@other_host, nil, %{reason: "acceptance test"})
      DomainBlockCache.refresh()

      page = page_object(ctx.outsider, "From a blocked host")

      inner = %{
        "id" => "https://#{@other_host}/activities/create-b",
        "type" => "Create",
        "actor" => ctx.outsider.ap_id,
        "object" => page
      }

      assert :ok = InboxHandler.handle(announce(ctx.community, inner), ctx.community, :shared)
      refute Content.get_article_by_ap_id(page["id"])
    end

    test "wrapping is bounded to one level", ctx do
      inner_announce = %{
        "id" => "https://#{@community_host}/activities/announce-inner",
        "type" => "Announce",
        "actor" => ctx.community.ap_id,
        "object" => create_page(ctx.member, "Nested")
      }

      assert :ok =
               InboxHandler.handle(
                 announce(ctx.community, inner_announce),
                 ctx.community,
                 :shared
               )

      # An Announce inside an Announce is not unwrapped: otherwise the depth
      # is the sender's to choose.
      assert Repo.aggregate(Content.Article, :count, :id) == 0
    end

    test "an ordinary Mastodon boost still behaves as a boost", ctx do
      # The carrier path must not swallow the object-wrapping form.
      page = page_object(ctx.member, "A boosted post")

      activity = announce(ctx.community, page)

      assert :ok = InboxHandler.handle(activity, ctx.community, :shared)
      assert Repo.aggregate(Federation.Announce, :count, :id) == 1
    end
  end

  # --- helpers ---

  defp lemmy_fixture(name) do
    Path.join([__DIR__, "..", "..", "support", "fixtures", name])
    |> File.read!()
    |> Jason.decode!()
  end

  defp create_actor_at(ap_id, username, type \\ "Person") do
    n = System.unique_integer([:positive])
    domain = ap_id |> URI.parse() |> Map.fetch!(:host)

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: ap_id,
      username: username,
      domain: domain,
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://#{domain}/inbox-#{n}",
      actor_type: type,
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp announce(group, object) do
    %{
      "id" => "https://#{group.domain}/activities/announce-#{System.unique_integer([:positive])}",
      "type" => "Announce",
      "actor" => group.ap_id,
      "object" => object,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }
  end

  defp create_page(actor, title) do
    %{
      "id" => "https://#{actor.domain}/activities/create-#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => actor.ap_id,
      "object" => page_object(actor, title),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }
  end

  defp page_object(actor, title) do
    n = System.unique_integer([:positive])

    %{
      "id" => "https://#{actor.domain}/post/#{n}",
      "type" => "Page",
      "name" => title,
      "content" => "<p>#{title}</p>",
      "attributedTo" => actor.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }
  end

  defp remote_article(actor, board) do
    n = System.unique_integer([:positive])

    {:ok, %{article: article}} =
      Content.create_remote_article(
        %{
          title: "Theirs",
          body: "Body",
          slug: "ga-remote-#{n}",
          ap_id: "https://#{actor.domain}/post/#{n}",
          remote_actor_id: actor.id,
          visibility: "public"
        },
        [board.id]
      )

    article
  end

  defp local_article(user, board) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Local",
          body: "Body",
          slug: "ga-art-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end

  defp create_board do
    %Board{}
    |> Board.changeset(%{
      name: "Board",
      slug: "ga-#{System.unique_integer([:positive])}",
      ap_enabled: true
    })
    |> Repo.insert!()
  end

  defp create_user do
    role = Repo.one!(from r in Setup.Role, where: r.name == "user")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "ga#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_actor(domain, name, type \\ "Person") do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://#{domain}/#{if type == "Group", do: "c", else: "u"}/#{name}-#{n}",
      username: "#{name}#{n}",
      domain: domain,
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://#{domain}/inbox-#{n}",
      actor_type: type,
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
