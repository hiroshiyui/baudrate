defmodule Baudrate.Content.ModerationAuthorizedInContextTest do
  @moduledoc """
  Acceptance gate for ADR 0016 on article moderation.

  The rule is that authorization happens *inside the context function*, against
  freshly loaded state — not at mount, and not in the LiveView. It did not hold
  here: `toggle_pin_article/1` and `toggle_lock_article/1` took no actor at all,
  `soft_delete_article/2` checked nothing, and `ArticleLive` computed
  `can_pin`/`can_lock`/`can_delete` once in `mount/3` and read them on events
  that could arrive an hour later.

  Losing a role revokes sessions, so a demoted admin was already stopped. Losing
  a *board moderator* grant does not, which is what these tests are about: the
  socket is still valid, and the right is gone.
  """

  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Content
  alias Baudrate.Repo
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()

    author = user("user")
    moderator = user("user")
    outsider = user("user")

    {:ok, board} =
      Content.create_board(%{
        name: "Mod Board",
        slug: "mod-#{System.unique_integer([:positive])}"
      })

    {:ok, _} = Content.add_board_moderator(board.id, moderator.id)

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Subject",
          body: "Body",
          slug: "subj-#{System.unique_integer([:positive])}",
          user_id: author.id
        },
        [board.id]
      )

    %{article: article, author: author, moderator: moderator, outsider: outsider, board: board}
  end

  describe "a board moderator whose grant is removed" do
    test "can no longer pin, even holding the article it could pin a moment ago", ctx do
      assert {:ok, pinned} = Content.toggle_pin_article(ctx.article, ctx.moderator)
      assert pinned.pinned

      {1, _} = Content.remove_board_moderator(ctx.board.id, ctx.moderator.id)

      # The caller still holds a perfectly good %Article{} and %User{} — the
      # exact state a LiveView keeps in its assigns across an event.
      assert Content.toggle_pin_article(pinned, ctx.moderator) == {:error, :unauthorized}
      assert Repo.get!(Content.Article, ctx.article.id).pinned
    end

    test "can no longer lock", ctx do
      assert {:ok, locked} = Content.toggle_lock_article(ctx.article, ctx.moderator)
      assert locked.locked

      {1, _} = Content.remove_board_moderator(ctx.board.id, ctx.moderator.id)

      assert Content.toggle_lock_article(locked, ctx.moderator) == {:error, :unauthorized}
      assert Repo.get!(Content.Article, ctx.article.id).locked
    end

    test "can no longer delete", ctx do
      {1, _} = Content.remove_board_moderator(ctx.board.id, ctx.moderator.id)

      assert Content.soft_delete_article(ctx.article, deleted_by: ctx.moderator.id) ==
               {:error, :unauthorized}

      assert is_nil(Repo.get!(Content.Article, ctx.article.id).deleted_at)
    end
  end

  describe "the check is in the context, not the caller" do
    test "an unrelated member cannot pin, lock or delete", ctx do
      assert Content.toggle_pin_article(ctx.article, ctx.outsider) == {:error, :unauthorized}
      assert Content.toggle_lock_article(ctx.article, ctx.outsider) == {:error, :unauthorized}

      assert Content.soft_delete_article(ctx.article, deleted_by: ctx.outsider.id) ==
               {:error, :unauthorized}
    end

    test "no actor at all is refused, rather than treated as trusted", ctx do
      assert Content.toggle_pin_article(ctx.article, nil) == {:error, :unauthorized}
      assert Content.soft_delete_article(ctx.article) == {:error, :unauthorized}
    end

    test "a stale struct without its role loaded is still judged correctly", ctx do
      # `can_delete_article?` matches on `%{role: %{name: "admin"}}`. Handed a
      # user whose :role was never preloaded, a naive check would fall through
      # to the board-moderator branch and quietly deny an admin. The context
      # reloads instead.
      admin = user("admin")
      bare = %{admin | role: %Ecto.Association.NotLoaded{}}

      assert {:ok, _} = Content.toggle_pin_article(ctx.article, bare)
    end

    test "the author may still delete their own article", ctx do
      assert {:ok, deleted} = Content.soft_delete_article(ctx.article, deleted_by: ctx.author.id)
      assert deleted.deleted_at
      assert deleted.deleted_by_id == ctx.author.id
    end
  end

  test "a remote deletion is authorized by the inbox and says so", ctx do
    # The federation path checks that the signer owns the object, then passes
    # `remote: true`. Without that marker it would be refused like any other
    # unattributed delete — which is the point: neither path reaches the delete
    # without having been authorized somewhere explicit.
    assert {:ok, deleted} = Content.soft_delete_article(ctx.article, remote: true)
    assert deleted.deleted_at
    assert is_nil(deleted.deleted_by_id)
  end

  defp user(role_name) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in Setup.User, where: u.id == ^user.id), set: [status: "active"])
    Repo.get!(Setup.User, user.id) |> Repo.preload(:role)
  end
end
