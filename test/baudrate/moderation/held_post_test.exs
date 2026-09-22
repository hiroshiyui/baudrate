defmodule Baudrate.Moderation.HeldPostTest do
  @moduledoc """
  The acceptance gate for held posts (Phase 5C, ADR 0065).

    * **A held post is not content.** It creates no article and no comment,
      so it is in no listing, no feed, no search and no outbox — structurally,
      not because each of those remembered to exclude it.
    * **Approval is publication**, as the author, once: the held row goes in
      the transaction that creates the post, so a second approval publishes
      nothing. What can have changed since the submission is checked again.
    * **Who reviews what**: staff everything, a board moderator only what is
      wholly inside the boards they moderate.
    * **Nothing is lost on the way**: the orphan image sweep spares a held
      post's uploads, a rejection keeps the text for the author and for
      staff, and retention removes it 90 days after review.
  """
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Content
  alias Baudrate.Content.{Article, ArticleImage, Board, BoardModerator, Comment, CommentImage}
  alias Baudrate.Moderation.{HeldPost, HeldPosts}
  alias Baudrate.Notification.Notification
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.{Setting, User}

  setup do
    Setup.seed_roles_and_permissions()

    Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
      Plug.Conn.send_resp(conn, 404, "")
    end)

    Repo.insert!(%Setting{key: "hold_first_posts", value: "2"})

    %{board: board(), admin: member("admin"), newcomer: member()}
  end

  defp board(attrs \\ %{}) do
    %Board{}
    |> Board.changeset(
      Map.merge(%{name: "Board", slug: "held-#{System.unique_integer([:positive])}"}, attrs)
    )
    |> Repo.insert!()
  end

  defp member(role_name \\ "user") do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))
    n = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "held#{n}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [status: "active"])
    user |> Repo.reload() |> Repo.preload(:role)
  end

  defp article_attrs(user, extra \\ %{}) do
    Map.merge(
      %{
        "title" => "My first post",
        "body" => "Hello, everyone.",
        "slug" => "held-#{System.unique_integer([:positive])}",
        "user_id" => user.id
      },
      extra
    )
  end

  defp submit(user, board, opts \\ []),
    do: Content.submit_article(article_attrs(user), [board.id], opts)

  describe "what is held" do
    test "a new account's first posts are held, and nothing is published", ctx do
      assert {:held, %HeldPost{kind: "article", reason: "first_posts", status: "pending"}} =
               submit(ctx.newcomer, ctx.board)

      assert Repo.aggregate(Article, :count) == 0
      assert Repo.aggregate(Comment, :count) == 0
    end

    test "only as many as the setting says: posts still up end it", ctx do
      author = member()

      {:ok, %{article: a1}} = Content.create_article(article_attrs(author), [ctx.board.id])
      assert {:held, _} = submit(author, ctx.board)

      {:ok, %{article: a2}} = Content.create_article(article_attrs(author), [ctx.board.id])
      assert {:ok, %{article: a3}} = submit(author, ctx.board)

      # A removed post no longer counts, as it does not for trust.
      for article <- [a1, a2] do
        {:ok, _} = Content.soft_delete_article(article, deleted_by: author.id)
      end

      assert {:held, _} = submit(author, ctx.board)
      assert a3.user_id == author.id
    end

    test "staff and bots are never held", ctx do
      assert {:ok, _} = submit(ctx.admin, ctx.board)
      assert {:ok, _} = submit(member("moderator"), ctx.board)

      bot = member()
      Repo.update_all(from(u in User, where: u.id == ^bot.id), set: [is_bot: true])
      refute HeldPosts.first_post?(bot.id)
    end

    test "0 turns it off", ctx do
      Repo.update_all(from(s in Setting, where: s.key == "hold_first_posts"), set: [value: "0"])
      assert {:ok, _} = submit(ctx.newcomer, ctx.board)
    end

    test "only a composer's submission is held; create_article publishes", ctx do
      assert {:ok, _} = Content.create_article(article_attrs(ctx.newcomer), [ctx.board.id])
    end

    test "a held comment is not a comment either", ctx do
      {:ok, %{article: article}} =
        Content.create_article(article_attrs(ctx.admin), [ctx.board.id])

      assert {:held, %HeldPost{kind: "comment", article_id: id}} =
               Content.submit_comment(%{
                 "body" => "First!",
                 "article_id" => article.id,
                 "user_id" => ctx.newcomer.id
               })

      assert id == article.id
      assert Content.list_comments_for_article(article) == []
    end

    test "a held post has passed the gates a published one must", ctx do
      {:ok, _} =
        Baudrate.Auth.issue_sanction(ctx.admin, ctx.newcomer, "silence",
          reason: "Spam",
          expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
        )

      assert {:error, :account, :account_silenced, _} = submit(ctx.newcomer, ctx.board)
      assert Repo.aggregate(HeldPost, :count) == 0
    end

    test "the people who can review it are told", ctx do
      {:held, held} = submit(ctx.newcomer, ctx.board)

      assert Repo.exists?(
               from(n in Notification,
                 where:
                   n.user_id == ^ctx.admin.id and n.type == "held_post" and
                     fragment("?->>'held_post_id' = ?", n.data, ^to_string(held.id))
               )
             )
    end
  end

  describe "approval is publication" do
    test "it publishes as the author, with its images and poll, and deletes the row", ctx do
      image = orphan_image(ctx.newcomer)

      {:held, held} =
        submit(ctx.newcomer, ctx.board,
          image_ids: [image.id],
          poll: %{
            mode: "single",
            closes_at: DateTime.utc_now() |> DateTime.add(86_400, :second),
            options: [%{text: "Yes", position: 0}, %{text: "No", position: 1}]
          }
        )

      assert {:ok, %Article{} = article} = HeldPosts.approve(held, ctx.admin)

      article = Repo.preload(article, [:boards, :article_images, poll: :options])
      assert article.user_id == ctx.newcomer.id
      assert article.ap_id
      assert Enum.map(article.boards, & &1.id) == [ctx.board.id]
      assert Enum.map(article.article_images, & &1.id) == [image.id]
      assert Enum.map(article.poll.options, & &1.text) == ["Yes", "No"]
      assert DateTime.diff(article.poll.closes_at, DateTime.utc_now()) > 86_000

      refute Repo.get(HeldPost, held.id)

      assert Repo.exists?(
               from(n in Notification,
                 where:
                   n.user_id == ^ctx.newcomer.id and n.type == "post_approved" and
                     n.article_id == ^article.id
               )
             )

      assert Repo.exists?(
               from(l in Baudrate.Moderation.Log,
                 where: l.action == "approve_held_post" and l.target_id == ^article.id
               )
             )
    end

    test "a comment is published into its thread, answering the comment it answered", ctx do
      {:ok, %{article: article}} =
        Content.create_article(article_attrs(ctx.admin), [ctx.board.id])

      {:ok, parent} =
        Content.create_comment(%{
          "body" => "Question?",
          "article_id" => article.id,
          "user_id" => ctx.admin.id
        })

      {:held, held} =
        Content.submit_comment(%{
          "body" => "Answer.",
          "article_id" => article.id,
          "parent_id" => parent.id,
          "user_id" => ctx.newcomer.id
        })

      assert {:ok, %Comment{} = comment} = HeldPosts.approve(held, ctx.admin)
      assert comment.parent_id == parent.id
      assert comment.user_id == ctx.newcomer.id
    end

    test "two approvals publish once", ctx do
      {:held, held} = submit(ctx.newcomer, ctx.board)

      assert {:ok, _} = HeldPosts.approve(held, ctx.admin)
      assert {:error, :not_found} = HeldPosts.approve(held, member("moderator"))
      assert Repo.aggregate(Article, :count) == 1
    end

    test "the claim rolls back a publication that lost the race", ctx do
      {:held, held} = submit(ctx.newcomer, ctx.board)
      # Another moderator's approval committed between the lookup and ours.
      Repo.delete!(held)

      assert {:error, :claim_held_post, :already_reviewed, _} =
               Content.create_article(article_attrs(ctx.newcomer), [ctx.board.id],
                 held_post: held
               )

      assert Repo.aggregate(Article, :count) == 0
    end

    test "an author who may no longer act is not published", ctx do
      {:held, held} = submit(ctx.newcomer, ctx.board)

      {:ok, _} =
        Baudrate.Auth.issue_sanction(ctx.admin, ctx.newcomer, "silence",
          reason: "Spam",
          expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
        )

      assert {:error, :account_silenced} = HeldPosts.approve(held, ctx.admin)
      assert Repo.get(HeldPost, held.id)
    end

    test "a board the author lost is dropped, and none left refuses", ctx do
      open = ctx.board
      closed = board(%{min_role_to_post: "moderator"})

      held = hold_directly(ctx.newcomer, [open.id, closed.id])
      assert {:ok, article} = HeldPosts.approve(held, ctx.admin)
      assert Enum.map(Repo.preload(article, :boards).boards, & &1.id) == [open.id]

      held = hold_directly(ctx.newcomer, [closed.id])
      assert {:error, :no_boards} = HeldPosts.approve(held, ctx.admin)
    end

    test "a comment on an article locked or removed since is not published", ctx do
      {:ok, %{article: article}} =
        Content.create_article(article_attrs(ctx.admin), [ctx.board.id])

      {:held, held} =
        Content.submit_comment(%{
          "body" => "Late",
          "article_id" => article.id,
          "user_id" => ctx.newcomer.id
        })

      Repo.update_all(from(a in Article, where: a.id == ^article.id), set: [locked: true])
      assert {:error, :cannot_comment} = HeldPosts.approve(held, ctx.admin)

      Repo.update_all(from(a in Article, where: a.id == ^article.id),
        set: [locked: false, deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      assert {:error, :article_gone} = HeldPosts.approve(held, ctx.admin)
    end

    test "approval does not spend the author's hourly allowance", ctx do
      Repo.insert!(%Setting{key: "new_account_days", value: "3"})
      Repo.insert!(%Setting{key: "new_account_posts", value: "3"})
      BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})
      {:held, held} = submit(ctx.newcomer, ctx.board)

      # From here on, any place taken in a bucket is refused.
      BaudrateWeb.RateLimiter.Sandbox.set_global_response({:deny, 60_000})
      assert {:ok, _} = HeldPosts.approve(held, ctx.admin)
    end
  end

  describe "who reviews what" do
    setup ctx do
      board_mod = member()
      other = board()
      Repo.insert!(%BoardModerator{board_id: ctx.board.id, user_id: board_mod.id})
      %{board_mod: board_mod, other: other}
    end

    test "a board moderator reviews what is wholly inside their boards", ctx do
      mine = hold_directly(ctx.newcomer, [ctx.board.id])
      cross = hold_directly(ctx.newcomer, [ctx.board.id, ctx.other.id])
      theirs = hold_directly(ctx.newcomer, [ctx.other.id])
      boardless = hold_directly(ctx.newcomer, [])

      ids =
        HeldPosts.paginate_for_reviewer(ctx.board_mod).held_posts |> Enum.map(& &1.id)

      assert ids == [mine.id]

      for held <- [cross, theirs, boardless] do
        assert {:error, :not_found} = HeldPosts.approve(held, ctx.board_mod)
        assert {:error, :not_found} = HeldPosts.reject(held, ctx.board_mod, nil)
      end

      assert {:ok, _} = HeldPosts.approve(mine, ctx.board_mod)

      staff_ids =
        HeldPosts.paginate_for_reviewer(ctx.admin).held_posts |> Enum.map(& &1.id)

      assert Enum.sort(staff_ids) == Enum.sort([cross.id, theirs.id, boardless.id])
    end

    test "a comment is reviewed by who moderates its article's boards", ctx do
      {:ok, %{article: inside}} =
        Content.create_article(article_attrs(ctx.admin), [ctx.board.id])

      {:ok, %{article: outside}} =
        Content.create_article(article_attrs(ctx.admin), [ctx.board.id, ctx.other.id])

      {:held, in_scope} =
        Content.submit_comment(%{
          "body" => "a",
          "article_id" => inside.id,
          "user_id" => ctx.newcomer.id
        })

      {:held, out_of_scope} =
        Content.submit_comment(%{
          "body" => "b",
          "article_id" => outside.id,
          "user_id" => ctx.newcomer.id
        })

      assert HeldPosts.get_pending_for_reviewer(in_scope.id, ctx.board_mod)
      refute HeldPosts.get_pending_for_reviewer(out_of_scope.id, ctx.board_mod)
      assert HeldPosts.count_pending(ctx.board_mod) == 1
    end

    test "a board moderator is told only about what they can review", ctx do
      {:held, _} = submit(ctx.newcomer, ctx.board)
      held_elsewhere = hold_directly(ctx.newcomer, [ctx.other.id])
      Baudrate.Notification.Hooks.notify_post_held(held_elsewhere)

      notified =
        Repo.all(
          from(n in Notification,
            where: n.user_id == ^ctx.board_mod.id and n.type == "held_post",
            select: fragment("?->>'held_post_id'", n.data)
          )
        )

      assert length(notified) == 1
      refute to_string(held_elsewhere.id) in notified
    end
  end

  describe "rejection and withdrawal" do
    test "a rejection keeps the text, tells the author, and is purged after 90 days", ctx do
      {:held, held} = submit(ctx.newcomer, ctx.board)

      assert {:ok, rejected} = HeldPosts.reject(held, ctx.admin, "  Off topic here.  ")
      assert rejected.status == "rejected"
      assert rejected.review_note == "Off topic here."
      assert rejected.body == "Hello, everyone."

      assert Repo.exists?(
               from(n in Notification,
                 where: n.user_id == ^ctx.newcomer.id and n.type == "post_rejected"
               )
             )

      # A rejection is final: it cannot be approved afterwards.
      assert {:error, :not_found} = HeldPosts.approve(rejected, ctx.admin)

      assert [%{id: id}] = HeldPosts.list_for_author(ctx.newcomer.id)
      assert id == held.id

      assert HeldPosts.purge_rejected() == 0
      later = DateTime.utc_now() |> DateTime.add(91 * 86_400, :second)
      assert HeldPosts.purge_rejected(now: later) == 1
    end

    test "the author may withdraw a pending post, but not erase a rejected one", ctx do
      {:held, pending} = submit(ctx.newcomer, ctx.board)
      {:held, other} = submit(ctx.newcomer, ctx.board)
      {:ok, _} = HeldPosts.reject(other, ctx.admin, nil)

      # Somebody else's id withdraws nothing.
      HeldPosts.withdraw(ctx.admin.id, pending.id)
      assert Repo.get(HeldPost, pending.id)

      HeldPosts.withdraw(ctx.newcomer.id, pending.id)
      HeldPosts.withdraw(ctx.newcomer.id, other.id)

      refute Repo.get(HeldPost, pending.id)
      assert Repo.get(HeldPost, other.id)
    end
  end

  describe "the orphan image sweeps" do
    test "spare the uploads a pending post names, and release them once it is decided", ctx do
      article_image = orphan_image(ctx.newcomer)
      comment_image = orphan_comment_image(ctx.newcomer)

      {:ok, %{article: article}} =
        Content.create_article(article_attrs(ctx.admin), [ctx.board.id])

      {:held, held_article} = submit(ctx.newcomer, ctx.board, image_ids: [article_image.id])

      {:held, _held_comment} =
        Content.submit_comment(
          %{"body" => "Look", "article_id" => article.id, "user_id" => ctx.newcomer.id},
          image_ids: [comment_image.id]
        )

      age_images()
      cutoff = DateTime.utc_now() |> DateTime.add(-86_400, :second)

      Content.delete_orphan_article_images(cutoff)
      Content.delete_orphan_comment_images(cutoff)
      assert Repo.get(ArticleImage, article_image.id)
      assert Repo.get(CommentImage, comment_image.id)

      {:ok, _} = HeldPosts.reject(held_article, ctx.admin, nil)
      Content.delete_orphan_article_images(cutoff)
      refute Repo.get(ArticleImage, article_image.id)
    end
  end

  test "it is swept by retention with the rest", ctx do
    {:held, held} = submit(ctx.newcomer, ctx.board)
    {:ok, _} = HeldPosts.reject(held, ctx.admin, nil)

    counts = Baudrate.Retention.run(now: DateTime.utc_now() |> DateTime.add(91 * 86_400, :second))
    assert counts.held_posts == 1
  end

  # --- helpers ---

  # Holds with exactly these boards, bypassing the composer's own checks, so
  # the reviewer scope can be tested against boards the author could not
  # post in.
  defp hold_directly(author, board_ids) do
    {:ok, held} =
      HeldPosts.hold_article(article_attrs(author), board_ids, [], "first_posts", nil)

    held
  end

  defp orphan_image(user) do
    %ArticleImage{}
    |> ArticleImage.changeset(%{
      filename: "#{:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)}.webp",
      storage_path: "/nonexistent",
      width: 10,
      height: 10,
      user_id: user.id
    })
    |> Repo.insert!()
  end

  defp orphan_comment_image(user) do
    %CommentImage{}
    |> CommentImage.changeset(%{
      filename: "#{:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)}.webp",
      storage_path: "/nonexistent",
      width: 10,
      height: 10,
      user_id: user.id
    })
    |> Repo.insert!()
  end

  defp age_images do
    past = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second) |> DateTime.truncate(:second)
    Repo.update_all(ArticleImage, set: [inserted_at: past])
    Repo.update_all(CommentImage, set: [inserted_at: past])
  end
end
