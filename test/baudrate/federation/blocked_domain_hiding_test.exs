defmodule Baudrate.Federation.BlockedDomainHidingTest do
  @moduledoc """
  Acceptance gate for ADR 0030: blocking a domain hides what it already sent,
  everywhere a guest or a member can look, and unblocking brings it back.

  Nothing is deleted and no column is stamped — hiding is a query-time filter —
  so every listing has to carry the predicate, and each one is a separate
  query. **Add every new listing query here.**

  The marker strings are the point: the test seeds an article, a comment and a
  timeline item from the blocked domain carrying a unique marker, and fails if the
  marker appears on any surface. A listing that forgets the filter shows the
  marker, whatever else it does.
  """
  use Baudrate.DataCase, async: false

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.{Article, ArticleBoost, ArticleTag, Board, Bookmark, Comment}
  alias Baudrate.Content.{Bookmarks, CommentBoost, ReadTracking, Search, Tags}
  alias Baudrate.Federation
  alias Baudrate.Federation.{DomainBlockCache, DomainBlocks, TimelineItem, Follows, RemoteActor}
  alias Baudrate.Federation.RemoteActors
  alias Baudrate.Setup

  @blocked "blocked.example"
  @friendly "friendly.example"

  setup do
    Setup.seed_roles_and_permissions()
    Setup.set_setting("ap_federation_mode", "blocklist")
    DomainBlockCache.refresh()

    board = create_board()
    user = create_user()

    marker = "zqxblocked#{System.unique_integer([:positive])}"
    safe = "zqxsafe#{System.unique_integer([:positive])}"

    blocked_actor = create_remote_actor(@blocked)
    friendly_actor = create_remote_actor(@friendly)

    {:ok, %{article: hidden}} = create_remote_article(board, blocked_actor, marker)
    {:ok, %{article: shown}} = create_remote_article(board, friendly_actor, safe)

    %{
      board: board,
      user: user,
      marker: marker,
      safe: safe,
      blocked_actor: blocked_actor,
      friendly_actor: friendly_actor,
      hidden: hidden,
      shown: shown
    }
  end

  defp block! do
    {:ok, block} = DomainBlocks.block_domain(@blocked, nil, %{reason: "acceptance test"})
    DomainBlockCache.refresh()
    block
  end

  defp create_board do
    %Board{}
    |> Board.changeset(%{name: "Board", slug: "board-#{System.unique_integer([:positive])}"})
    |> Repo.insert!()
  end

  defp create_user do
    role = Repo.one!(from r in Setup.Role, where: r.name == "user")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_remote_actor(domain) do
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

  defp create_remote_article(board, actor, title) do
    n = System.unique_integer([:positive])

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
  end

  defp titles(articles), do: Enum.map(articles, & &1.title)

  describe "board listings" do
    test "paginate_articles_for_board/2 hides it from a guest", ctx do
      block!()
      result = Content.paginate_articles_for_board(ctx.board, user: nil)

      refute ctx.marker in titles(result.articles)
      assert ctx.safe in titles(result.articles)
      assert result.total == 1
    end

    test "paginate_articles_for_board/2 hides it from a member", ctx do
      block!()
      result = Content.paginate_articles_for_board(ctx.board, user: ctx.user)

      refute ctx.marker in titles(result.articles)
    end

    test "list_articles_for_board/1 hides it", ctx do
      block!()
      refute ctx.marker in titles(Content.list_articles_for_board(ctx.board))
    end
  end

  describe "search" do
    test "search_articles/2 hides it — this also backs the public /ap/search", ctx do
      block!()
      result = Search.search_articles(ctx.marker, user: nil)

      refute ctx.marker in titles(result.articles)
    end

    test "search_comments/2 hides a comment from the blocked domain", ctx do
      create_remote_comment(ctx.shown, ctx.blocked_actor, "comment saying #{ctx.marker}")
      block!()

      assert %{comments: []} = Search.search_comments(ctx.marker, user: nil)
    end

    test "search_comments/2 hides a friendly comment on a blocked domain's article", ctx do
      # The article's title reaches the page through the preload, so filtering
      # only the comment side would leak it.
      create_remote_comment(ctx.hidden, ctx.friendly_actor, "reply about #{ctx.safe}")
      block!()

      assert %{comments: []} = Search.search_comments(ctx.safe, user: nil)
    end
  end

  describe "comment lists" do
    test "list_comments_for_article/1 hides a comment from the blocked domain", ctx do
      create_remote_comment(ctx.shown, ctx.blocked_actor, "comment saying #{ctx.marker}")
      block!()

      bodies = Content.list_comments_for_article(ctx.shown, nil) |> Enum.map(& &1.body)
      refute Enum.any?(bodies, &String.contains?(&1, ctx.marker))
    end

    # `paginate_comments_for_article/3` is what the article page actually
    # renders, and it applies the filter in four separate places: the root
    # count, the root page, `fetch_descendants/4` and `deleted_ancestor_ids/3`.
    # One test per place, because each is its own query.
    test "paginate_comments_for_article/3 hides a root comment, in the page and the count", ctx do
      create_remote_comment(ctx.shown, ctx.friendly_actor, "friendly root #{ctx.safe}")
      create_remote_comment(ctx.shown, ctx.blocked_actor, "blocked root #{ctx.marker}")
      block!()

      result = Content.paginate_comments_for_article(ctx.shown, ctx.user)

      refute mentions?(result.comments, ctx.marker)
      assert mentions?(result.comments, ctx.safe)

      assert result.total_roots == 1,
             "the root count is a separate query from the root page: a count " <>
               "that forgot the filter offers a pager page that renders empty"
    end

    test "paginate_comments_for_article/3 hides a reply from the blocked domain", ctx do
      root = create_remote_comment(ctx.shown, ctx.friendly_actor, "friendly root #{ctx.safe}")

      create_remote_comment(ctx.shown, ctx.blocked_actor, "blocked reply #{ctx.marker}",
        parent: root
      )

      block!()

      result = Content.paginate_comments_for_article(ctx.shown, ctx.user)

      refute mentions?(result.comments, ctx.marker),
             "descendants are fetched by a separate query per thread level"

      assert mentions?(result.comments, ctx.safe)
    end

    test "paginate_comments_for_article/3 raises no placeholder for a hidden reply", ctx do
      # A soft-deleted comment is rendered as a placeholder only when a visible
      # reply sits below it. The scan that decides that is its own query, so if
      # it forgets the filter the placeholder appears — telling the reader that
      # someone on the blocked domain replied here, and keeping a deleted
      # comment on the page for the sake of a reply nobody can see.
      root = create_remote_comment(ctx.shown, ctx.friendly_actor, "withdrawn #{ctx.safe}")

      create_remote_comment(ctx.shown, ctx.blocked_actor, "blocked reply #{ctx.marker}",
        parent: root
      )

      soft_delete_comment!(root)
      block!()

      result = Content.paginate_comments_for_article(ctx.shown, ctx.user)

      assert result.comments == []
      assert result.total_roots == 0
    end

    test "count_comments_for_article/1 does not count a comment from the blocked domain", ctx do
      create_remote_comment(ctx.shown, ctx.friendly_actor, "friendly #{ctx.safe}")
      create_remote_comment(ctx.shown, ctx.blocked_actor, "blocked #{ctx.marker}")
      block!()

      # Both callers are public surfaces — the AP `Article` object and the
      # JSON-LD block on the article page — so a count that includes hidden
      # replies tells a guest they exist and lets them be counted.
      assert Content.count_comments_for_article(ctx.shown) == 1
    end
  end

  describe "tag pages" do
    test "articles_by_tag/2 hides it", ctx do
      for article <- [ctx.hidden, ctx.shown] do
        %ArticleTag{}
        |> Ecto.Changeset.change(%{article_id: article.id, tag: "sometag"})
        |> Repo.insert!()
      end

      block!()
      result = Tags.articles_by_tag("sometag", user: nil)

      refute ctx.marker in titles(result.articles)
      assert ctx.safe in titles(result.articles)
    end
  end

  describe "bookmarks" do
    test "list_bookmarks/2 hides one bookmarked before the block", ctx do
      for article <- [ctx.hidden, ctx.shown] do
        %Bookmark{}
        |> Ecto.Changeset.change(%{user_id: ctx.user.id, article_id: article.id})
        |> Repo.insert!()
      end

      block!()

      %{bookmarks: bookmarks} = Bookmarks.list_bookmarks(ctx.user.id)
      bookmarked = Enum.map(bookmarks, & &1.article.title)

      refute ctx.marker in bookmarked
      assert ctx.safe in bookmarked

      # The count is a separate query from the page. At one per page, a count
      # that forgot the filter offers a second page that renders empty.
      assert %{total_pages: 1} = Bookmarks.list_bookmarks(ctx.user.id, per_page: 1)
    end
  end

  describe "profile activity" do
    test "boosting does not keep it visible", ctx do
      for article <- [ctx.hidden, ctx.shown] do
        %ArticleBoost{}
        |> Ecto.Changeset.change(%{
          user_id: ctx.user.id,
          article_id: article.id,
          ap_id: "https://local.example/ap/boosts/#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()
      end

      block!()

      boosted =
        Content.list_recent_boosted_articles_by_user(ctx.user.id, 10, viewer: nil)
        |> Enum.map(fn {_ts, a} -> a.title end)

      refute ctx.marker in boosted
      assert ctx.safe in boosted
    end

    test "boosting a comment does not keep it visible", ctx do
      friendly = create_remote_comment(ctx.shown, ctx.friendly_actor, "friendly #{ctx.safe}")
      blocked = create_remote_comment(ctx.shown, ctx.blocked_actor, "blocked #{ctx.marker}")

      for comment <- [friendly, blocked], do: boost_comment!(ctx.user, comment)

      block!()

      boosted =
        Content.list_recent_boosted_comments_by_user(ctx.user.id, 10, viewer: nil)
        |> Enum.map(fn {_ts, c} -> c end)

      refute mentions?(boosted, ctx.marker)
      assert mentions?(boosted, ctx.safe)
    end
  end

  describe "unread badges" do
    test "unread_board_ids/2 does not light up a board for it", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old = ~U[2000-01-01 00:00:00Z]
      reader = %{ctx.user | inserted_at: DateTime.add(now, -86_400, :second)}

      recent = fn article, at ->
        Repo.update_all(from(a in Article, where: a.id == ^article.id),
          set: [last_activity_at: at]
        )
      end

      # Positive control: the badge does light up for content we still show.
      recent.(ctx.shown, now)
      recent.(ctx.hidden, old)
      block!()
      assert MapSet.member?(ReadTracking.unread_board_ids(reader, [ctx.board.id]), ctx.board.id)

      recent.(ctx.shown, old)
      recent.(ctx.hidden, now)
      refute MapSet.member?(ReadTracking.unread_board_ids(reader, [ctx.board.id]), ctx.board.id)
    end
  end

  describe "the personal feed" do
    test "a boost by a followed actor hides the blocked author's item", ctx do
      # The follower never followed the blocked author, so severing follows on
      # block does not reach this item: only the filter does.
      {:ok, _} = Follows.create_user_follow(ctx.user, ctx.friendly_actor)
      accept_follow(ctx.user, ctx.friendly_actor)

      timeline_item =
        create_timeline_item(ctx.blocked_actor, ctx.marker, boosted_by: ctx.friendly_actor)

      assert timeline_item.id in timeline_item_ids(ctx.user)

      block!()

      refute timeline_item.id in timeline_item_ids(ctx.user)
      # The pager count is hand-written SQL that mirrors the query; if it does
      # not mirror this too, the feed offers a page that renders empty.
      assert Federation.list_timeline_items(ctx.user).total == 0
    end

    test "suspending one actor empties the feed page and its count", ctx do
      # A suspension is the same predicate as a domain block
      # (`Filters.hidden_actor_ids/0` matches either), which is what stops the
      # two diverging as listings are added — so it belongs in this gate.
      {:ok, _} = Follows.create_user_follow(ctx.user, ctx.friendly_actor)
      accept_follow(ctx.user, ctx.friendly_actor)

      item = create_timeline_item(ctx.friendly_actor, ctx.safe, [])

      assert item.id in timeline_item_ids(ctx.user)
      assert Federation.list_timeline_items(ctx.user).total == 1

      {:ok, _} = RemoteActors.suspend(ctx.friendly_actor, nil, "acceptance test")

      result = Federation.list_timeline_items(ctx.user)

      assert result.items == []

      assert result.total == 0,
             "the count is hand-written SQL beside the Ecto query: with only " <>
               "the domain half of the predicate, suspending an actor left " <>
               "its items in `total` and offered a page that renders empty"
    end

    test "muting a followed actor hides their boosts as well as their own posts", ctx do
      {:ok, _} = Follows.create_user_follow(ctx.user, ctx.friendly_actor)
      accept_follow(ctx.user, ctx.friendly_actor)

      own = create_timeline_item(ctx.friendly_actor, ctx.safe, [])

      # On an Announce, `remote_actor_id` is the boosted *author* — someone the
      # muter need not follow — and `boosted_by_actor_id` is the actor they do
      # follow and have just muted. Testing the author column alone left a
      # muted account's boosts in the feed, which is the one thing a mute is
      # asked to stop. A block would sever the follow and make the join drop
      # these rows; a mute deliberately severs nothing.
      elsewhere = create_remote_actor("elsewhere.example")

      boost =
        create_timeline_item(elsewhere, "#{ctx.safe}boosted", boosted_by: ctx.friendly_actor)

      assert own.id in timeline_item_ids(ctx.user)
      assert boost.id in timeline_item_ids(ctx.user)
      assert Federation.list_timeline_items(ctx.user).total == 2

      {:ok, _} = Auth.mute_remote_actor(ctx.user, ctx.friendly_actor.ap_id)

      result = Federation.list_timeline_items(ctx.user)

      assert timeline_item_ids(ctx.user) == []
      assert result.total == 0
    end
  end

  describe "single pages" do
    test "the article page refuses it, for everyone including an admin", ctx do
      block!()

      article =
        Content.get_article_by_slug!(ctx.hidden.slug) |> Repo.preload([:boards, :remote_actor])

      admin = admin_user()

      refute BaudrateWeb.ArticleHelpers.user_can_view_article?(article, nil)
      refute BaudrateWeb.ArticleHelpers.user_can_view_article?(article, ctx.user)
      refute BaudrateWeb.ArticleHelpers.user_can_view_article?(article, admin)

      # A permalink that still renders is not a block: the link is what gets
      # passed around.
      shown =
        Content.get_article_by_slug!(ctx.shown.slug) |> Repo.preload([:boards, :remote_actor])

      assert BaudrateWeb.ArticleHelpers.user_can_view_article?(shown, nil)
    end
  end

  describe "unblocking" do
    test "brings all of it back", ctx do
      block = block!()

      refute ctx.marker in titles(Content.list_articles_for_board(ctx.board))

      {:ok, _} = DomainBlocks.unblock_domain(block)
      DomainBlockCache.refresh()

      # Nothing was deleted and no column was stamped, so this needs no repair
      # step. That is the whole point of hiding at query time.
      assert ctx.marker in titles(Content.list_articles_for_board(ctx.board))
    end
  end

  describe "allowlist mode" do
    test "content from a domain that is not allowed is hidden too", ctx do
      Setup.set_setting("ap_domain_allowlist", @friendly)
      Setup.set_setting("ap_federation_mode", "allowlist")
      DomainBlockCache.refresh()

      titles = titles(Content.list_articles_for_board(ctx.board))

      refute ctx.marker in titles
      assert ctx.safe in titles
    end
  end

  defp admin_user do
    role = Repo.one!(from r in Setup.Role, where: r.name == "admin")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "admin_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_remote_comment(article, actor, body, opts \\ []) do
    parent = Keyword.get(opts, :parent)

    %Comment{}
    |> Ecto.Changeset.change(%{
      body: body,
      ap_id: "https://#{actor.domain}/comments/#{System.unique_integer([:positive])}",
      article_id: article.id,
      parent_id: parent && parent.id,
      remote_actor_id: actor.id,
      visibility: "public"
    })
    |> Repo.insert!()
  end

  defp soft_delete_comment!(comment) do
    Repo.update_all(from(c in Comment, where: c.id == ^comment.id),
      set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    comment
  end

  defp boost_comment!(user, comment) do
    %CommentBoost{}
    |> Ecto.Changeset.change(%{
      user_id: user.id,
      comment_id: comment.id,
      ap_id: "https://local.example/ap/boosts/#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp bodies(comments), do: Enum.map(comments, & &1.body)

  defp mentions?(comments, marker),
    do: Enum.any?(bodies(comments), &String.contains?(&1, marker))

  defp create_timeline_item(actor, marker, opts) do
    booster = Keyword.get(opts, :boosted_by)

    %TimelineItem{}
    |> Ecto.Changeset.change(%{
      ap_id: "https://#{actor.domain}/notes/#{System.unique_integer([:positive])}",
      remote_actor_id: actor.id,
      boosted_by_actor_id: booster && booster.id,
      activity_type: if(booster, do: "Announce", else: "Create"),
      object_type: "Note",
      body: "timeline item saying #{marker}",
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp accept_follow(user, actor) do
    Repo.update_all(
      from(uf in Baudrate.Federation.UserFollow,
        where: uf.user_id == ^user.id and uf.remote_actor_id == ^actor.id
      ),
      set: [state: "accepted", accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end

  defp timeline_item_ids(user) do
    Federation.list_timeline_items(user).items
    |> Enum.flat_map(fn
      %{source: :remote, timeline_item: fi} -> [fi.id]
      _ -> []
    end)
  end
end
