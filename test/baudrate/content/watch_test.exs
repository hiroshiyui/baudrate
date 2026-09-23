defmodule Baudrate.Content.WatchTest do
  @moduledoc """
  Acceptance gate for [ADR 0070](../../../doc/adr/0070-a-member-hears-about-what-they-chose.md):
  a member is told about a board or thread only because they chose to watch
  it, a board watch reports threads and never comments, and one event is
  never two notices.

  A new way for an article to reach a board belongs in the "board watchers"
  block: an arrival that skips `Articles.announce_arrival/2` is a post the
  watchers never hear about.
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.{Board, Watch}
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Moderation.HeldPosts
  alias Baudrate.Notification.Hooks
  alias Baudrate.Notification.Notification
  alias Baudrate.Setup
  alias Baudrate.Setup.{Setting, User}

  setup do
    Setup.seed_roles_and_permissions()

    Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
      Plug.Conn.send_resp(conn, 404, "")
    end)

    %{board: board(), author: member(), watcher: member()}
  end

  describe "toggling a watch" do
    test "watches and unwatches a board", %{board: board, watcher: watcher} do
      assert {:ok, %Watch{}} = Content.toggle_board_watch(watcher, board.id)
      assert Content.board_watched?(watcher, board.id)
      assert {:ok, :removed} = Content.toggle_board_watch(watcher, board.id)
      refute Content.board_watched?(watcher, board.id)
    end

    test "watches and unwatches a thread", %{board: board, author: author, watcher: watcher} do
      article = article!(author, board)
      assert {:ok, %Watch{}} = Content.toggle_article_watch(watcher, article.id)
      assert Content.article_watched?(watcher, article.id)
      assert {:ok, :removed} = Content.toggle_article_watch(watcher, article.id)
    end

    test "refuses a board or thread the member cannot open", %{author: author, watcher: watcher} do
      staff = board(%{min_role_to_view: "moderator"})
      article = article!(author, staff)

      assert {:error, :not_found} = Content.toggle_board_watch(watcher, staff.id)
      assert {:error, :not_found} = Content.toggle_article_watch(watcher, article.id)
      assert {:error, :not_found} = Content.toggle_board_watch(watcher, -1)
    end

    test "refuses a withdrawn thread", %{board: board, author: author, watcher: watcher} do
      article = article!(author, board)

      Repo.update_all(from(a in Content.Article, where: a.id == ^article.id),
        set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      assert {:error, :not_found} = Content.toggle_article_watch(watcher, article.id)
    end

    test "a watch can be removed after access is lost", %{board: board, watcher: watcher} do
      {:ok, _} = Content.toggle_board_watch(watcher, board.id)
      {:ok, _} = Content.update_board(board, %{min_role_to_view: "moderator"})

      assert {:ok, :removed} = Content.toggle_board_watch(watcher, board.id)
    end

    test "another member's watch cannot be removed by id", %{board: board, watcher: watcher} do
      {:ok, watch} = Content.toggle_board_watch(watcher, board.id)
      assert {:error, :not_found} = Content.delete_watch(member(), watch.id)
      assert Content.board_watched?(watcher, board.id)
    end
  end

  # ADR 0070 decision 1. Each of these is a place a forum might
  # "helpfully" watch on the member's behalf; none of them may.
  describe "nothing watches on the member's behalf" do
    test "writing, replying, bookmarking and liking create no watch", %{
      board: board,
      author: author,
      watcher: watcher
    } do
      article = article!(watcher, board)
      other = article!(author, board)
      {:ok, _} = comment!(other, watcher)
      {:ok, _} = Content.toggle_article_bookmark(watcher.id, other.id)
      {:ok, _} = Content.toggle_article_like(watcher.id, other.id)

      assert Repo.aggregate(Watch, :count) == 0
      refute Content.article_watched?(watcher, article.id)
    end
  end

  describe "board watchers" do
    setup %{board: board, watcher: watcher} do
      {:ok, _} = Content.toggle_board_watch(watcher, board.id)
      :ok
    end

    test "are told about a new thread written here", ctx do
      article = article!(ctx.author, ctx.board)

      assert [n] = notices(ctx.watcher, "watched_board_post")
      assert n.article_id == article.id
      assert n.actor_user_id == ctx.author.id
      assert n.data["board_id"] == ctx.board.id
    end

    test "are told about a thread arriving from another server", ctx do
      actor = remote_actor()
      {:ok, %{article: article}} = remote_article!(actor, ctx.board)

      assert [n] = notices(ctx.watcher, "watched_board_post")
      assert n.article_id == article.id
      assert n.actor_remote_actor_id == actor.id
    end

    test "are told about a thread forwarded into the board", ctx do
      elsewhere = board()
      article = article!(ctx.author, elsewhere)
      {:ok, _} = Content.forward_article_to_board(article, ctx.board, ctx.author)

      assert [%{article_id: id}] = notices(ctx.watcher, "watched_board_post")
      assert id == article.id
    end

    test "are told once when the inbox cross-posts a thread into the board", ctx do
      elsewhere = board()
      actor = remote_actor()
      {:ok, %{article: article}} = remote_article!(actor, elsewhere)

      :ok = Content.cross_post_article(article, [ctx.board.id])
      :ok = Content.cross_post_article(article, [ctx.board.id])

      assert [%{article_id: id}] = notices(ctx.watcher, "watched_board_post")
      assert id == article.id
    end

    test "are not told about comments", ctx do
      article = article!(ctx.author, ctx.board)
      {:ok, _} = comment!(article, member())

      assert notices(ctx.watcher, "watched_thread_reply") == []
      assert length(notices(ctx.watcher, "watched_board_post")) == 1
    end

    test "are not told about their own thread", ctx do
      _ = article!(ctx.watcher, ctx.board)
      assert notices(ctx.watcher, "watched_board_post") == []
    end

    test "are not told about a followers-only thread from elsewhere", ctx do
      {:ok, _} = remote_article!(remote_actor(), ctx.board, "followers_only")
      assert notices(ctx.watcher, "watched_board_post") == []
    end

    test "who can no longer open the board are not told", ctx do
      {:ok, _} = Content.update_board(ctx.board, %{min_role_to_view: "moderator"})
      _ = article!(member("moderator"), ctx.board)

      assert notices(ctx.watcher, "watched_board_post") == []
    end

    test "are told only when a held thread is approved", ctx do
      Repo.insert!(%Setting{key: "hold_first_posts", value: "1"})
      newcomer = member()

      {:held, held} =
        Content.submit_article(
          %{
            "title" => "Held",
            "body" => "Body",
            "slug" => "held-#{System.unique_integer([:positive])}",
            "user_id" => newcomer.id
          },
          [ctx.board.id]
        )

      assert notices(ctx.watcher, "watched_board_post") == []

      {:ok, _} = HeldPosts.approve(held, member("admin"))
      assert [_] = notices(ctx.watcher, "watched_board_post")
    end
  end

  describe "thread watchers" do
    setup %{board: board, author: author, watcher: watcher} do
      article = article!(author, board)
      {:ok, _} = Content.toggle_article_watch(watcher, article.id)
      %{article: article}
    end

    test "are told about a new comment", ctx do
      commenter = member()
      {:ok, comment} = comment!(ctx.article, commenter)

      assert [n] = notices(ctx.watcher, "watched_thread_reply")
      assert n.comment_id == comment.id
      assert n.actor_user_id == commenter.id
    end

    test "are told about a public comment from another server", ctx do
      actor = remote_actor()
      comment = remote_comment!(ctx.article, actor, "public")
      Hooks.notify_thread_watchers(comment)

      assert [n] = notices(ctx.watcher, "watched_thread_reply")
      assert n.actor_remote_actor_id == actor.id
    end

    test "are not told about a followers-only comment from another server", ctx do
      comment = remote_comment!(ctx.article, remote_actor(), "followers_only")
      Hooks.notify_thread_watchers(comment)

      assert notices(ctx.watcher, "watched_thread_reply") == []
    end

    test "are not told about their own comment", ctx do
      {:ok, _} = comment!(ctx.article, ctx.watcher)
      assert notices(ctx.watcher, "watched_thread_reply") == []
    end

    test "are not told about a comment by someone they blocked", ctx do
      blocked = member()
      {:ok, _} = Baudrate.Auth.block_user(ctx.watcher, blocked)
      {:ok, _} = comment!(ctx.article, blocked)

      assert notices(ctx.watcher, "watched_thread_reply") == []
    end

    # One event, one notice: the author of the thread watching it hears
    # "replied to your article", not that and "replied in a thread you watch".
    test "are not told twice about a reply already addressed to them", ctx do
      {:ok, _} = Content.toggle_article_watch(ctx.author, ctx.article.id)
      {:ok, parent} = comment!(ctx.article, ctx.watcher)
      {:ok, _} = comment!(ctx.article, member(), parent_id: parent.id)

      assert notices(ctx.author, "watched_thread_reply") == []
      assert [_] = notices(ctx.author, "reply_to_article") |> Enum.take(1)
      assert notices(ctx.watcher, "watched_thread_reply") == []
      assert [_] = notices(ctx.watcher, "reply_to_comment")
    end

    test "are not told twice about a comment that mentions them", ctx do
      {:ok, _} = comment!(ctx.article, member(), body: "Look, @#{ctx.watcher.username}")

      assert notices(ctx.watcher, "watched_thread_reply") == []
      assert [_] = notices(ctx.watcher, "mention")
    end

    test "who can no longer open the thread are not told", ctx do
      {:ok, _} = Content.update_board(ctx.board, %{min_role_to_view: "moderator"})
      {:ok, _} = comment!(ctx.article, member("moderator"))

      assert notices(ctx.watcher, "watched_thread_reply") == []
    end
  end

  # --- helpers ---

  defp notices(user, type) do
    Repo.all(
      from(n in Notification,
        where: n.user_id == ^user.id and n.type == ^type,
        order_by: [asc: n.id]
      )
    )
  end

  defp board(attrs \\ %{}) do
    %Board{}
    |> Board.changeset(
      Map.merge(%{name: "Board", slug: "watch-#{System.unique_integer([:positive])}"}, attrs)
    )
    |> Repo.insert!()
  end

  defp member(role_name \\ "user") do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))
    n = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "watch#{n}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [status: "active"])
    user |> Repo.reload() |> Repo.preload(:role)
  end

  defp article!(user, board) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Thread",
          body: "Body",
          slug: "thread-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end

  defp comment!(article, user, opts \\ []) do
    Content.create_comment(%{
      "body" => Keyword.get(opts, :body, "A reply"),
      "article_id" => article.id,
      "user_id" => user.id,
      "parent_id" => Keyword.get(opts, :parent_id)
    })
  end

  defp remote_actor do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/w#{n}",
      username: "w#{n}",
      domain: "remote.example",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/w#{n}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp remote_article!(actor, board, visibility \\ "public") do
    n = System.unique_integer([:positive])

    Content.create_remote_article(
      %{
        title: "From elsewhere",
        body: "body",
        slug: "remote-#{n}",
        ap_id: "https://remote.example/articles/#{n}",
        remote_actor_id: actor.id,
        visibility: visibility
      },
      [board.id]
    )
  end

  defp remote_comment!(article, actor, visibility) do
    n = System.unique_integer([:positive])

    {:ok, comment} =
      Content.create_remote_comment(%{
        body: "from elsewhere",
        body_html: "<p>from elsewhere</p>",
        ap_id: "https://remote.example/notes/#{n}",
        article_id: article.id,
        remote_actor_id: actor.id,
        visibility: visibility
      })

    comment
  end
end
