defmodule Baudrate.Content.RemoteVisibilityTest do
  @moduledoc """
  A remote object ingested as `followers_only` or `direct` must not appear on
  any surface that lists content.

  Ingest deliberately keeps whatever addressing a peer sent, so these rows do
  exist in the database; the row-level gate
  (`ArticleHelpers.user_can_view_article?/2`) refuses them to everyone,
  including admins. Every listing query has to agree with that gate, and each
  one is a separate query — so each one is checked here.
  """
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{Article, ArticleBoost, ArticleTag, Board, Bookmark, Comment}
  alias Baudrate.Content.{Bookmarks, CommentBoost, ReadTracking, Search, Tags}
  alias Baudrate.Federation
  alias Baudrate.Federation.{Follows, RemoteActor, TimelineItem}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()

    board = create_board()
    actor = create_remote_actor()
    user = create_user()
    marker = "zqxmarker#{System.unique_integer([:positive])}"

    {:ok, %{article: hidden}} = create_remote_article(board, actor, marker, "followers_only")
    {:ok, %{article: shown}} = create_remote_article(board, actor, "#{marker}pub", "public")

    %{board: board, actor: actor, user: user, marker: marker, hidden: hidden, shown: shown}
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

  defp create_remote_actor do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/a#{n}",
      username: "a#{n}",
      domain: "remote.example",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/a#{n}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp create_remote_article(board, actor, title, visibility) do
    n = System.unique_integer([:positive])

    Content.create_remote_article(
      %{
        title: title,
        body: "body of #{title}",
        slug: "slug-#{n}",
        ap_id: "https://remote.example/articles/#{n}",
        remote_actor_id: actor.id,
        visibility: visibility
      },
      [board.id]
    )
  end

  # The same three arguments as `create_remote_article/4`: the visibility is
  # what is being tested, so it is never defaulted.
  defp create_remote_comment(article, actor, body, visibility, opts \\ []) do
    parent = Keyword.get(opts, :parent)

    %Comment{}
    |> Ecto.Changeset.change(%{
      body: body,
      ap_id: "https://remote.example/comments/#{System.unique_integer([:positive])}",
      article_id: article.id,
      parent_id: parent && parent.id,
      remote_actor_id: actor.id,
      visibility: visibility
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

  defp titles(articles), do: Enum.map(articles, & &1.title)

  defp mentions?(comments, marker),
    do: Enum.any?(comments, &String.contains?(&1.body, marker))

  # A followers-only reply and a public one on the same public article, so
  # every listing test has both a negative and a positive control.
  defp two_replies(ctx) do
    {
      create_remote_comment(ctx.shown, ctx.actor, "#{ctx.marker}secret", "followers_only"),
      create_remote_comment(ctx.shown, ctx.actor, "#{ctx.marker}open", "public")
    }
  end

  defp secret(ctx), do: "#{ctx.marker}secret"
  defp open(ctx), do: "#{ctx.marker}open"

  describe "board listings" do
    test "paginate_articles_for_board/2 hides it from a guest", ctx do
      result = Content.paginate_articles_for_board(ctx.board, user: nil)

      refute ctx.marker in titles(result.articles)
      assert "#{ctx.marker}pub" in titles(result.articles)
      assert result.total == 1
    end

    test "paginate_articles_for_board/2 hides it from a member", ctx do
      result = Content.paginate_articles_for_board(ctx.board, user: ctx.user)

      refute ctx.marker in titles(result.articles)
    end

    test "list_articles_for_board/1 hides it", ctx do
      refute ctx.marker in titles(Content.list_articles_for_board(ctx.board))
    end
  end

  describe "search" do
    test "search_articles/2 hides it — this also backs the public /ap/search", ctx do
      result = Search.search_articles(ctx.marker, user: nil)

      refute ctx.marker in titles(result.articles)
    end

    test "search_comments/2 hides a remote reply to it", ctx do
      %Comment{}
      |> Ecto.Changeset.change(%{
        body: "reply mentioning #{ctx.marker}",
        ap_id: "https://remote.example/comments/#{System.unique_integer([:positive])}",
        article_id: ctx.hidden.id,
        remote_actor_id: ctx.actor.id,
        visibility: "public"
      })
      |> Repo.insert!()

      result = Search.search_comments(ctx.marker, user: nil)

      assert result.comments == []
    end
  end

  describe "comment lists" do
    test "list_comments_for_article/2 hides a followers-only reply from a guest", ctx do
      two_replies(ctx)

      comments = Content.list_comments_for_article(ctx.shown, nil)

      refute mentions?(comments, secret(ctx))
      assert mentions?(comments, open(ctx))
    end

    test "list_comments_for_article/2 hides it from a member too", ctx do
      # A separate function head, because a member also carries block/mute
      # lists — and those filters are not where this check can live.
      two_replies(ctx)

      comments = Content.list_comments_for_article(ctx.shown, ctx.user)

      refute mentions?(comments, secret(ctx))
      assert mentions?(comments, open(ctx))
    end

    # `paginate_comments_for_article/3` is what the article page actually
    # renders, and it applies the filter in four separate places: the root
    # count, the root page, `fetch_descendants/4` and `deleted_ancestor_ids/3`.
    # One test per place, because each is its own query.
    test "paginate_comments_for_article/3 hides a root reply, in the page and the count", ctx do
      two_replies(ctx)

      result = Content.paginate_comments_for_article(ctx.shown, ctx.user)

      refute mentions?(result.comments, secret(ctx))
      assert mentions?(result.comments, open(ctx))

      assert result.total_roots == 1,
             "the root count is a separate query from the root page: a count " <>
               "that forgot the filter offers a pager page that renders empty"
    end

    test "paginate_comments_for_article/3 hides a followers-only descendant", ctx do
      root = create_remote_comment(ctx.shown, ctx.actor, open(ctx), "public")
      create_remote_comment(ctx.shown, ctx.actor, secret(ctx), "followers_only", parent: root)

      result = Content.paginate_comments_for_article(ctx.shown, ctx.user)

      refute mentions?(result.comments, secret(ctx)),
             "descendants are fetched by a separate query per thread level"

      assert mentions?(result.comments, open(ctx))
    end

    test "paginate_comments_for_article/3 raises no placeholder for a hidden reply", ctx do
      # A soft-deleted comment is rendered as a placeholder only when a visible
      # reply sits below it. The scan that decides that is its own query, so if
      # it forgets the filter the placeholder appears — which says a reply
      # exists here, for a reply nobody may read.
      root = create_remote_comment(ctx.shown, ctx.actor, open(ctx), "public")
      create_remote_comment(ctx.shown, ctx.actor, secret(ctx), "followers_only", parent: root)
      soft_delete_comment!(root)

      result = Content.paginate_comments_for_article(ctx.shown, ctx.user)

      assert result.comments == []
      assert result.total_roots == 0
    end

    test "count_comments_for_article/1 does not count a followers-only reply", ctx do
      two_replies(ctx)

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

      result = Tags.articles_by_tag("sometag", user: nil)

      refute ctx.marker in titles(result.articles)
      assert "#{ctx.marker}pub" in titles(result.articles)
    end
  end

  describe "bookmarks" do
    test "list_bookmarks/2 hides one bookmarked while it was reachable", ctx do
      for article <- [ctx.hidden, ctx.shown] do
        %Bookmark{}
        |> Ecto.Changeset.change(%{user_id: ctx.user.id, article_id: article.id})
        |> Repo.insert!()
      end

      %{bookmarks: bookmarks} = Bookmarks.list_bookmarks(ctx.user.id)
      bookmarked = Enum.map(bookmarks, & &1.article.title)

      refute ctx.marker in bookmarked
      assert "#{ctx.marker}pub" in bookmarked
    end
  end

  describe "profile activity" do
    test "boosting does not make it public", ctx do
      for article <- [ctx.hidden, ctx.shown] do
        %ArticleBoost{}
        |> Ecto.Changeset.change(%{
          user_id: ctx.user.id,
          article_id: article.id,
          ap_id: "https://local.example/ap/boosts/#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()
      end

      boosted =
        Content.list_recent_boosted_articles_by_user(ctx.user.id, 10, viewer: nil)
        |> Enum.map(fn {_ts, a} -> a.title end)

      refute ctx.marker in boosted
      assert "#{ctx.marker}pub" in boosted
    end

    test "boosting a comment does not make it public either", ctx do
      {hidden, shown} = two_replies(ctx)

      for comment <- [hidden, shown], do: boost_comment!(ctx.user, comment)

      boosted =
        Content.list_recent_boosted_comments_by_user(ctx.user.id, 10, viewer: nil)
        |> Enum.map(fn {_ts, c} -> c end)

      refute mentions?(boosted, secret(ctx))
      assert mentions?(boosted, open(ctx))
    end
  end

  describe "unread badges" do
    test "unread_board_ids/2 does not light up a board for it", ctx do
      # `create_remote_article/2` leaves `last_activity_at` nil, which alone
      # keeps a row out of the unread comparison, so it has to be set here.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old = ~U[2000-01-01 00:00:00Z]

      # Nothing older than the reader's registration counts as unread, and the
      # reader was created in this test's setup. `unread_board_ids/2` takes the
      # timestamp from the struct it is given, so backdate it there rather than
      # dating the articles into the future.
      reader = %{ctx.user | inserted_at: DateTime.add(now, -86_400, :second)}

      recent = fn article, at ->
        Repo.update_all(from(a in Article, where: a.id == ^article.id),
          set: [last_activity_at: at]
        )
      end

      # Positive control first: with the public article recent, the badge
      # lights up. Without this the refute below would pass on a board that
      # never lights up at all, and prove nothing.
      recent.(ctx.shown, now)
      recent.(ctx.hidden, old)
      assert MapSet.member?(ReadTracking.unread_board_ids(reader, [ctx.board.id]), ctx.board.id)

      # Now only the hidden article is recent.
      recent.(ctx.shown, old)
      recent.(ctx.hidden, now)
      refute MapSet.member?(ReadTracking.unread_board_ids(reader, [ctx.board.id]), ctx.board.id)
    end
  end

  describe "the personal feed" do
    test "a followed actor's own followers-only post is shown — the viewer is a follower", ctx do
      # The boundary this gate does *not* police. `list_timeline_items/2` joins
      # on an accepted `user_follows` row, so a followers-only item can only
      # reach a viewer who is in fact a follower of the actor that published
      # it. Refusing it here would hide from followers the very posts addressed
      # to them.
      follow!(ctx.user, ctx.actor)
      item = create_timeline_item(ctx.actor, "followers_only", [])

      assert item.id in timeline_item_ids(ctx.user)
      assert Federation.list_timeline_items(ctx.user).total == 1
    end

    # An Announce is the case where the follow-join proves nothing about the
    # item's author: the accepted `user_follows` row is matched against
    # `boosted_by_actor_id`, the booster, while `remote_actor_id` is a third
    # actor the viewer has never followed. So a hostile instance that
    # Announces a victim's `followers_only` post to a booster local people
    # follow would put that post — title, body and attachments — in the feeds
    # of people who were never in its audience. Same shape as the article and
    # comment leaks this file exists for.
    test "a boosted followers-only post is hidden — the viewer follows the booster, not the author",
         ctx do
      booster = create_remote_actor()
      follow!(ctx.user, booster)

      item = create_timeline_item(ctx.actor, "followers_only", boosted_by: booster)
      public = create_timeline_item(ctx.actor, "public", boosted_by: booster)

      assert public.id in timeline_item_ids(ctx.user)

      refute item.id in timeline_item_ids(ctx.user),
             "an Announce carries an author the viewer need not follow, so " <>
               "followers-only is not theirs to read"

      assert Federation.list_timeline_items(ctx.user).total == 1,
             "the count must agree with the page, or the pager offers an empty one"
    end

    test "a direct post never reaches a timeline, even from someone you follow", ctx do
      follow!(ctx.user, ctx.actor)

      item = create_timeline_item(ctx.actor, "direct")
      public = create_timeline_item(ctx.actor, "public")

      assert public.id in timeline_item_ids(ctx.user)

      refute item.id in timeline_item_ids(ctx.user),
             "a DM is the Messaging context's channel, never a timeline row"
    end
  end

  defp follow!(user, actor) do
    {:ok, _} = Follows.create_user_follow(user, actor)

    Repo.update_all(
      from(uf in Baudrate.Federation.UserFollow,
        where: uf.user_id == ^user.id and uf.remote_actor_id == ^actor.id
      ),
      set: [state: "accepted", accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end

  defp create_timeline_item(actor, visibility, opts \\ []) do
    booster = Keyword.get(opts, :boosted_by)

    %TimelineItem{}
    |> Ecto.Changeset.change(%{
      ap_id: "https://remote.example/notes/#{System.unique_integer([:positive])}",
      remote_actor_id: actor.id,
      boosted_by_actor_id: booster && booster.id,
      activity_type: if(booster, do: "Announce", else: "Create"),
      object_type: "Note",
      body: "timeline item",
      visibility: visibility,
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp timeline_item_ids(user) do
    Federation.list_timeline_items(user).items
    |> Enum.flat_map(fn
      %{source: :remote, timeline_item: fi} -> [fi.id]
      _ -> []
    end)
  end
end
