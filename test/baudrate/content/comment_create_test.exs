defmodule Baudrate.Content.CommentCreateTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    import Ecto.Query
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

  defp create_board do
    slug = "board-#{System.unique_integer([:positive])}"

    %Board{}
    |> Board.changeset(%{name: "Board", slug: slug})
    |> Repo.insert!()
  end

  defp create_article(user, board) do
    slug = "article-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Test Article", body: "Body", slug: slug, user_id: user.id},
        [board.id]
      )

    article
  end

  describe "create_comment/1" do
    test "creates a local comment with rendered HTML" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      assert {:ok, comment} =
               Content.create_comment(%{
                 "body" => "**Hello** world",
                 "article_id" => article.id,
                 "user_id" => user.id
               })

      assert comment.body == "**Hello** world"
      assert comment.body_html =~ "<strong>Hello</strong>"
      assert comment.user_id == user.id
      assert comment.article_id == article.id
    end

    test "creates a threaded reply" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, parent} =
        Content.create_comment(%{
          "body" => "Parent comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      {:ok, reply} =
        Content.create_comment(%{
          "body" => "Reply to parent",
          "article_id" => article.id,
          "user_id" => user.id,
          "parent_id" => parent.id
        })

      assert reply.parent_id == parent.id
    end

    test "stamps local comment with AP ID for federation" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "Federable comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      # A path, not a fragment: `<actor>#note-N` dereferenced to the author's
      # Person document, so no peer could ever resolve the comment (ADR 0050).
      assert comment.ap_id == Baudrate.Federation.actor_uri(:comment, comment.id)
    end

    test "validates required fields" do
      assert {:error, changeset} = Content.create_comment(%{"body" => ""})
      assert %{body: _, article_id: _, user_id: _} = errors_on(changeset)
    end
  end

  describe "change_comment/2" do
    test "returns a changeset" do
      changeset = Content.change_comment()
      assert %Ecto.Changeset{} = changeset
    end
  end

  # Review finding (2026-11-02): only the article page checked whether a
  # thread took comments, against the copy it had loaded. A lock broadcasts
  # to board topics the page does not hear, so an open page kept posting into
  # a thread a moderator had just locked. The context now reads the thread.
  describe "the thread is judged as it stands, not as a page loaded it" do
    setup do
      user = create_user()
      board = create_board()
      %{user: user, article: create_article(user, board), board: board}
    end

    defp comment(ctx, extra \\ %{}) do
      Content.create_comment(
        Map.merge(
          %{"body" => "a reply", "article_id" => ctx.article.id, "user_id" => ctx.user.id},
          extra
        )
      )
    end

    test "an open thread takes a comment", ctx do
      assert {:ok, _} = comment(ctx)
    end

    test "a locked thread refuses one", ctx do
      Repo.update_all(
        Ecto.Query.from(a in Content.Article, where: a.id == ^ctx.article.id),
        set: [locked: true]
      )

      assert {:error, :not_commentable} = comment(ctx)
    end

    test "a deleted thread refuses one", ctx do
      {:ok, _} = Content.soft_delete_article(ctx.article, deleted_by: ctx.user.id)
      assert {:error, :not_commentable} = comment(ctx)
    end

    test "a reply's parent must be in the same thread", ctx do
      other = create_article(ctx.user, ctx.board)

      {:ok, elsewhere} =
        Content.create_comment(%{
          "body" => "elsewhere",
          "article_id" => other.id,
          "user_id" => ctx.user.id
        })

      assert {:error, :not_commentable} = comment(ctx, %{"parent_id" => elsewhere.id})
    end
  end
end
