defmodule Baudrate.PrivacySettingsTest do
  @moduledoc """
  Acceptance gate for [ADR 0073](../../doc/adr/0073-privacy-settings-shape-what-a-member-sees-and-who-finds-them.md):
  a member's privacy settings shape what they see and who finds them, never
  what anyone else may read.

    * A **muted server** is gone from every per-viewer listing — and its
      counts — for that member only, and refuses no interaction.
    * A **muted word** is matched as the admin filters match, and collapses
      rather than removes (the collapse itself is in the LiveView tests).
    * A **follow request** is no follower anywhere until approved.
    * An **undiscoverable** member is left out of the sitemap and the member
      search, and says so to other servers.
  """

  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query

  alias Baudrate.{Auth, Content, Federation, Repo}
  alias Baudrate.Content.{Board, Comment}
  alias Baudrate.Federation.{DeliveryJob, Follower, InboxHandler, KeyStore, RemoteActor}
  alias Baudrate.Federation.{TimelineItem, UserFollow}
  alias Baudrate.Moderation.{ContentFilter, PatternMatcher}
  alias Baudrate.Notification.Notification

  @muted "muted.example"

  setup do
    Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})

    Req.Test.stub(Federation.HTTPClient, fn conn -> Plug.Conn.send_resp(conn, 202, "") end)

    member = setup_user("user")
    {:ok, member} = KeyStore.ensure_user_keypair(member)

    board =
      Repo.insert!(
        Board.changeset(%Board{}, %{name: "B", slug: "b-#{System.unique_integer([:positive])}"})
      )

    %{
      member: member,
      board: board,
      muted_actor: remote_actor(@muted),
      other_actor: remote_actor("fine.example")
    }
  end

  # --- fixtures -------------------------------------------------------------

  defp remote_actor(domain) do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://#{domain}/users/a#{n}",
      username: "a#{n}",
      domain: domain,
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://#{domain}/users/a#{n}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp remote_article(board, actor, title) do
    n = System.unique_integer([:positive])

    {:ok, %{article: article}} =
      Content.create_remote_article(
        %{
          title: title,
          body: "body of #{title}",
          slug: "slug-#{n}",
          ap_id: "https://#{actor.domain}/articles/#{n}",
          remote_actor_id: actor.id,
          visibility: "public"
        },
        [board.id]
      )

    article
  end

  defp local_article(user, board, title) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: title,
          body: "b",
          slug: "l-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end

  defp remote_comment(article, actor, body, visibility \\ "public") do
    %Comment{}
    |> Ecto.Changeset.change(%{
      body: body,
      ap_id: "https://#{actor.domain}/comments/#{System.unique_integer([:positive])}",
      article_id: article.id,
      remote_actor_id: actor.id,
      visibility: visibility
    })
    |> Repo.insert!()
  end

  defp timeline_item(actor, marker, booster \\ nil) do
    %TimelineItem{}
    |> Ecto.Changeset.change(%{
      ap_id: "https://#{actor.domain}/notes/#{System.unique_integer([:positive])}",
      remote_actor_id: actor.id,
      boosted_by_actor_id: booster && booster.id,
      activity_type: if(booster, do: "Announce", else: "Create"),
      object_type: "Note",
      body: marker,
      visibility: "public",
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp follow_accepted(user, actor) do
    Repo.insert!(%UserFollow{
      user_id: user.id,
      remote_actor_id: actor.id,
      state: "accepted",
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      ap_id: "https://local.example/follows/#{System.unique_integer([:positive])}"
    })
  end

  defp jobs(type) do
    Repo.all(from(j in DeliveryJob, select: {j.inbox_url, j.activity_json}))
    |> Enum.filter(fn {_inbox, json} -> Jason.decode!(json)["type"] == type end)
  end

  defp follow_activity(remote, actor_uri) do
    %{
      "id" => "https://#{remote.domain}/follows/#{System.unique_integer([:positive])}",
      "type" => "Follow",
      "actor" => remote.ap_id,
      "object" => actor_uri
    }
  end

  # --- muted servers --------------------------------------------------------

  describe "a muted server" do
    test "is refused as this site, and normalized from a pasted URL or handle", %{member: member} do
      host = URI.parse(BaudrateWeb.Endpoint.url()).host
      assert {:error, _} = Auth.mute_domain(member, host)

      assert {:ok, %{domain: "muted.example"}} =
               Auth.mute_domain(member, "https://Muted.Example/@someone")

      assert {:error, _} = Auth.mute_domain(member, "@x@muted.example")
    end

    test "is gone from board lists and their counts, for the member only", ctx do
      remote_article(ctx.board, ctx.muted_actor, "from the muted server")
      remote_article(ctx.board, ctx.other_actor, "from elsewhere")
      {:ok, _} = Auth.mute_domain(ctx.member, @muted)

      mine = Content.paginate_articles_for_board(ctx.board, user: ctx.member)
      assert Enum.map(mine.articles, & &1.title) == ["from elsewhere"]
      assert mine.total == 1

      assert Content.paginate_articles_for_board(ctx.board, user: nil).total == 2
    end

    test "is gone from comments, both searches and the timeline, author and booster", ctx do
      article = local_article(ctx.member, ctx.board, "thread")
      remote_comment(article, ctx.muted_actor, "zzmutedcomment")
      follow_accepted(ctx.member, ctx.other_actor)
      follow_accepted(ctx.member, ctx.muted_actor)
      own = timeline_item(ctx.muted_actor, "zzmutedpost")
      boost = timeline_item(ctx.other_actor, "zzboostedbymuted", ctx.muted_actor)
      remote_article(ctx.board, ctx.muted_actor, "zzmutedtitle")
      Repo.update_all(Board, set: [min_role_to_view: "guest"])

      # Present before the mute, so the checks below are not vacuous.
      assert [_] = Content.paginate_comments_for_article(article, ctx.member).comments
      assert [_] = Content.search_comments("zzmutedcomment", user: ctx.member).comments
      assert [_] = Content.search_articles("zzmutedtitle", user: ctx.member).articles

      before =
        for %{source: :remote, timeline_item: fi} <-
              Federation.list_timeline_items(ctx.member).items,
            do: fi.id

      assert own.id in before and boost.id in before

      {:ok, _} = Auth.mute_domain(ctx.member, @muted)

      assert Content.paginate_comments_for_article(article, ctx.member).comments == []
      assert Content.search_comments("zzmutedcomment", user: ctx.member).comments == []
      assert Content.search_articles("zzmutedtitle", user: ctx.member).articles == []

      timeline = Federation.list_timeline_items(ctx.member)

      ids =
        for %{source: :remote, timeline_item: fi} <- timeline.items, do: fi.id

      refute own.id in ids
      refute boost.id in ids
      # The count mirrors the page — no remote item, the member's own article.
      assert timeline.total == length(timeline.items)
    end

    test "refuses its accounts' notifications", ctx do
      {:ok, _} = Auth.mute_domain(ctx.member, @muted)

      assert {:ok, :skipped} =
               Baudrate.Notification.create_notification(%{
                 type: "new_follower",
                 user_id: ctx.member.id,
                 actor_remote_actor_id: ctx.muted_actor.id
               })
    end

    test "unmuting brings everything back", ctx do
      remote_article(ctx.board, ctx.muted_actor, "back again")
      {:ok, mute} = Auth.mute_domain(ctx.member, @muted)
      assert Content.paginate_articles_for_board(ctx.board, user: ctx.member).total == 0

      Auth.unmute_domain(ctx.member, mute.id)
      assert Content.paginate_articles_for_board(ctx.board, user: ctx.member).total == 1
    end
  end

  # --- the timeline's comment strand (a gap found on the way) ---------------

  describe "remote replies in the timeline's comment strand" do
    test "a followers-only or direct reply is not shown, and the count agrees", ctx do
      article = local_article(ctx.member, ctx.board, "my thread")
      remote_comment(article, ctx.other_actor, "public reply")
      remote_comment(article, ctx.other_actor, "followers reply", "followers_only")
      remote_comment(article, ctx.other_actor, "direct reply", "direct")

      timeline = Federation.list_timeline_items(ctx.member)

      bodies =
        for %{source: source, comment: c} <- timeline.items,
            source in [:local_comment, :remote_comment],
            do: c.body

      assert "public reply" in bodies
      refute "followers reply" in bodies
      refute "direct reply" in bodies
      assert timeline.total == length(timeline.items)
    end
  end

  # --- muted words ----------------------------------------------------------

  describe "muted words" do
    test "match as the admin filters match, normal form included" do
      word = PatternMatcher.compile(%{"kind" => "word", "pattern" => "spoil"})
      part = PatternMatcher.compile(%{"kind" => "substring", "pattern" => "spoil"})

      refute PatternMatcher.any_match?([word], ["No spoilers here"])
      assert PatternMatcher.any_match?([part], ["No spoilers here"])
      # Fullwidth letters fold to the ordinary ones, as ContentFilter's do.
      assert PatternMatcher.any_match?([word], ["ＳＰＯＩＬ alert"])
      refute PatternMatcher.any_match?([], ["anything"])
    end

    test "are stored normalized and judged by the admin filters' rule", %{member: member} do
      assert {:ok, updated} =
               Auth.update_muted_keywords(member, [%{"kind" => "word", "pattern" => "  SPOIL  "}])

      assert updated.muted_keywords == [%{"kind" => "word", "pattern" => "spoil"}]

      assert ContentFilter.pattern_error("word", "!!!")

      assert {:error, _} =
               Auth.update_muted_keywords(member, [%{"kind" => "word", "pattern" => "!!!"}])

      assert {:error, _} =
               Auth.update_muted_keywords(member, [%{"kind" => "regex", "pattern" => "x"}])

      too_many = for i <- 1..51, do: %{"kind" => "word", "pattern" => "w#{i}"}
      assert {:error, _} = Auth.update_muted_keywords(member, too_many)
    end
  end

  # --- approving followers --------------------------------------------------

  describe "approving followers manually" do
    setup ctx do
      {:ok, member} = Auth.update_manually_approves_followers(ctx.member, true)
      actor_uri = Federation.actor_uri(:user, member.username)
      Repo.delete_all(DeliveryJob)
      %{member: member, actor_uri: actor_uri}
    end

    test "a remote Follow waits, with no Accept, and the member is asked", ctx do
      assert :ok =
               InboxHandler.handle(
                 follow_activity(ctx.other_actor, ctx.actor_uri),
                 ctx.other_actor,
                 {:user, ctx.member}
               )

      assert %Follower{accepted_at: nil} = Repo.one!(from(f in Follower))
      assert jobs("Accept") == []

      assert Repo.exists?(
               from(n in Notification,
                 where: n.user_id == ^ctx.member.id and n.type == "follow_request"
               )
             )
    end

    test "a waiting request is a follower nowhere", ctx do
      InboxHandler.handle(
        follow_activity(ctx.other_actor, ctx.actor_uri),
        ctx.other_actor,
        {:user, ctx.member}
      )

      refute Federation.follower_exists?(ctx.actor_uri, ctx.other_actor.ap_id)
      assert Federation.count_followers(ctx.actor_uri) == 0
      assert Federation.list_followers_of_user(ctx.member).remote == []
      assert Federation.Delivery.resolve_follower_inboxes(ctx.actor_uri) == []

      assert Federation.Delivery.resolve_follower_inboxes(ctx.actor_uri, include_pending: true) ==
               [ctx.other_actor.inbox]

      collection = Federation.followers_collection(ctx.actor_uri, %{"page" => "1"})
      assert collection["orderedItems"] == []
    end

    test "asking again sends no Accept and moves to the newest Follow", ctx do
      first = follow_activity(ctx.other_actor, ctx.actor_uri)
      second = follow_activity(ctx.other_actor, ctx.actor_uri)
      InboxHandler.handle(first, ctx.other_actor, {:user, ctx.member})
      InboxHandler.handle(second, ctx.other_actor, {:user, ctx.member})

      assert jobs("Accept") == []
      assert Repo.one!(from(f in Follower, select: f.activity_id)) == second["id"]
    end

    test "approving sends the Accept for the newest Follow; declining sends a Reject", ctx do
      approved = remote_actor("approved.example")
      declined = remote_actor("declined.example")
      follow = follow_activity(approved, ctx.actor_uri)
      InboxHandler.handle(follow, approved, {:user, ctx.member})
      InboxHandler.handle(follow_activity(declined, ctx.actor_uri), declined, {:user, ctx.member})

      %{remote: [a, d]} = Federation.list_follow_requests(ctx.member)
      assert :ok = Federation.approve_remote_follower(ctx.member, a.id)
      assert :ok = Federation.remove_remote_follower(ctx.member, d.id)

      assert [{inbox, json}] = jobs("Accept")
      assert inbox == approved.inbox
      assert Jason.decode!(json)["object"]["id"] == follow["id"]
      assert [{_, _}] = jobs("Reject")
      assert Federation.follower_exists?(ctx.actor_uri, approved.ap_id)
    end

    test "another member cannot approve this member's request", ctx do
      InboxHandler.handle(
        follow_activity(ctx.other_actor, ctx.actor_uri),
        ctx.other_actor,
        {:user, ctx.member}
      )

      [row] = Repo.all(Follower)
      stranger = setup_user("user")
      assert {:error, :not_found} = Federation.approve_remote_follower(stranger, row.id)
    end

    test "turning it off approves everyone waiting, and tells other servers", ctx do
      InboxHandler.handle(
        follow_activity(ctx.other_actor, ctx.actor_uri),
        ctx.other_actor,
        {:user, ctx.member}
      )

      asker = setup_user("user")
      {:ok, %{state: "pending"}} = Federation.create_local_follow(asker, ctx.member)

      {:ok, updated} = Auth.update_manually_approves_followers(ctx.member, false)

      refute updated.manually_approves_followers
      assert Federation.follower_exists?(ctx.actor_uri, ctx.other_actor.ap_id)
      assert Federation.local_follow_state(asker.id, ctx.member.id) == "accepted"
      assert [_] = jobs("Accept")
      # The Update(Person) carrying the new flag reaches the now-follower.
      assert [_ | _] = jobs("Update")
    end

    test "a local follow waits too, and a Move's carried-over follow does not", ctx do
      asker = setup_user("user")
      {:ok, %{state: "pending"}} = Federation.create_local_follow(asker, ctx.member)

      assert Repo.exists?(
               from(n in Notification,
                 where: n.user_id == ^ctx.member.id and n.type == "follow_request"
               )
             )

      assert {:ok, _} = Federation.approve_local_follower(ctx.member, asker.id)
      assert Federation.local_follow_state(asker.id, ctx.member.id) == "accepted"

      mover = setup_user("user")

      assert {:ok, %{state: "accepted"}} =
               Federation.create_local_follow(mover, ctx.member, system: true)
    end

    test "the actor says so", ctx do
      assert Federation.user_actor(ctx.member)["manuallyApprovesFollowers"] == true
    end
  end

  # --- discovery ------------------------------------------------------------

  describe "opting out of discovery" do
    setup ctx do
      {:ok, member} = Auth.update_discoverable(ctx.member, false)
      %{member: member}
    end

    test "leaves the member out of the member search, not out of mentions", ctx do
      term = String.slice(ctx.member.username, 0, 8)

      refute ctx.member.id in Enum.map(Auth.search_users_page(term).users, & &1.id)
      assert ctx.member.id in Enum.map(Auth.search_users(term), & &1.id)
    end

    test "leaves their articles out of the sitemap", ctx do
      Repo.update_all(Board, set: [min_role_to_view: "guest"])
      article = local_article(ctx.member, ctx.board, "not invited")

      refute article.slug in Enum.map(Content.Sitemap.public_article_slugs(0, 1000), &elem(&1, 0))
    end

    test "the actor says so", ctx do
      actor = Federation.user_actor(ctx.member)
      assert actor["discoverable"] == false
      assert actor["indexable"] == false
    end
  end
end
