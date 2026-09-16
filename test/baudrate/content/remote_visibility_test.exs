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
  alias Baudrate.Content.{Bookmarks, ReadTracking, Search, Tags}
  alias Baudrate.Federation.RemoteActor
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

  defp titles(articles), do: Enum.map(articles, & &1.title)

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
end
