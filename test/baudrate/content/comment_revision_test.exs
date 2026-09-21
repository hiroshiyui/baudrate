defmodule Baudrate.Content.CommentRevisionTest do
  @moduledoc """
  Acceptance gate for ADR 0060's first half: an edit is kept.

  Every rule the decision rests on gets a test of its own here — what a
  snapshot holds, who may write one, and what stops one being written. The
  federation half is gated in `Baudrate.Federation.PublisherTest` and the
  page in `BaudrateWeb.CommentHistoryLiveTest`.
  """
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{Board, Comment, CommentRevision}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name \\ "user") do
    import Ecto.Query
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

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
    %Board{}
    |> Board.changeset(%{name: "Board", slug: "board-#{System.unique_integer([:positive])}"})
    |> Repo.insert!()
  end

  defp create_article(user, board) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "A thread",
          body: "Body",
          slug: "cr-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end

  defp create_comment(user, article, attrs \\ %{}) do
    {:ok, comment} =
      Content.create_comment(
        Map.merge(
          %{"body" => "the original text", "article_id" => article.id, "user_id" => user.id},
          attrs
        )
      )

    comment
  end

  defp setup_thread(role \\ "user") do
    user = create_user(role)
    board = create_board()
    article = create_article(user, board)
    {user, article, create_comment(user, article)}
  end

  describe "update_comment/3 — the snapshot" do
    test "stores the text the edit replaced, not the text it wrote" do
      {user, _article, comment} = setup_thread()

      {:ok, updated} = Content.update_comment(comment, %{"body" => "the new text"}, user)

      assert updated.body == "the new text"
      assert [revision] = Content.list_comment_revisions(comment.id)
      assert revision.body == "the original text"
      assert revision.editor_id == user.id
      assert revision.comment_id == comment.id
    end

    test "re-renders body_html from the new body" do
      {user, _article, comment} = setup_thread()

      {:ok, updated} = Content.update_comment(comment, %{"body" => "# a heading"}, user)

      assert updated.body_html =~ "a heading"
      refute updated.body_html =~ "the original text"
    end

    test "editing the warning alone leaves the rendered body intact" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      comment = create_comment(user, article, %{"body" => "# a heading"})
      rendered = comment.body_html
      assert rendered =~ "a heading"

      {:ok, updated} = Content.update_comment(comment, %{"summary" => "spoilers"}, user)

      # Deriving body_html from `attrs["body"] || ""` would blank it here:
      # the changeset still passes, because validate_required sees the body
      # already on the struct.
      assert updated.body == "# a heading"
      assert updated.body_html == rendered
      assert updated.summary == "spoilers"
    end

    test "snapshots the content warning, so removing one leaves a trace" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      comment =
        create_comment(user, article, %{"summary" => "spoilers", "sensitive" => true})

      assert comment.summary == "spoilers"

      {:ok, updated} =
        Content.update_comment(comment, %{"body" => "now safe", "summary" => ""}, user)

      assert is_nil(updated.summary)

      assert [revision] = Content.list_comment_revisions(comment.id)
      assert revision.summary == "spoilers"
      assert revision.sensitive == true
    end

    test "accumulates a revision per edit, newest first" do
      {user, _article, comment} = setup_thread()

      {:ok, once} = Content.update_comment(comment, %{"body" => "second"}, user)
      {:ok, _twice} = Content.update_comment(once, %{"body" => "third"}, user)

      bodies = Content.list_comment_revisions(comment.id) |> Enum.map(& &1.body)
      assert bodies == ["second", "the original text"]
      assert Content.count_comment_revisions(comment.id) == 2
    end

    test "count_comment_revisions_for/1 answers for many comments in one query" do
      {user, article, comment} = setup_thread()
      untouched = create_comment(user, article, %{"body" => "never edited"})

      {:ok, _} = Content.update_comment(comment, %{"body" => "edited once"}, user)

      counts = Content.count_comment_revisions_for([comment.id, untouched.id])
      assert counts[comment.id] == 1
      refute Map.has_key?(counts, untouched.id)
      assert Content.count_comment_revisions_for([]) == %{}
    end
  end

  describe "update_comment/3 — who may edit" do
    test "the author may" do
      {user, _article, comment} = setup_thread()
      assert {:ok, _} = Content.update_comment(comment, %{"body" => "mine to fix"}, user)
    end

    test "another member may not, and no revision is written" do
      {_author, _article, comment} = setup_thread()
      stranger = create_user()

      assert {:error, :unauthorized} =
               Content.update_comment(comment, %{"body" => "not mine"}, stranger)

      assert Content.list_comment_revisions(comment.id) == []
      assert Repo.get!(Comment, comment.id).body == "the original text"
    end

    test "an admin may not either — deletion is moderation's tool, not editing (ADR 0060)" do
      {_author, _article, comment} = setup_thread()
      admin = create_user("admin")

      assert {:error, :unauthorized} =
               Content.update_comment(comment, %{"body" => "moderated"}, admin)

      assert Repo.get!(Comment, comment.id).body == "the original text"
    end

    test "can_edit_comment?/2 refuses a nil viewer and a remote comment" do
      {user, _article, comment} = setup_thread()

      refute Content.can_edit_comment?(nil, comment)
      refute Content.can_edit_comment?(user, %Comment{user_id: nil, remote_actor_id: 1})
      assert Content.can_edit_comment?(user, comment)
    end
  end

  describe "update_comment/3 — what it refuses" do
    test "a soft-deleted comment, which would otherwise republish a withdrawal" do
      {user, _article, comment} = setup_thread()
      {:ok, deleted} = Content.soft_delete_comment(comment, deleted_by: user.id)

      assert {:error, :not_found} =
               Content.update_comment(deleted, %{"body" => "back again"}, user)

      assert Content.list_comment_revisions(comment.id) == []
    end

    test "a body over the 64 KB bound" do
      {user, _article, comment} = setup_thread()
      too_long = String.duplicate("x", 65_537)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Content.update_comment(comment, %{"body" => too_long}, user)

      assert %{body: [_ | _]} = errors_on(changeset)
      # The failed edit rolls back with its snapshot: a revision must never
      # outlive the change it was recording.
      assert Content.list_comment_revisions(comment.id) == []
    end

    test "fields outside the allow-list are ignored, not applied" do
      {user, article, comment} = setup_thread()
      other_article = create_article(user, create_board())

      {:ok, updated} =
        Content.update_comment(
          comment,
          %{
            "body" => "fixed",
            "article_id" => other_article.id,
            "user_id" => 999_999,
            "visibility" => "followers_only",
            "ap_id" => "https://evil.example/ap/comments/1"
          },
          user
        )

      assert updated.article_id == article.id
      assert updated.user_id == user.id
      assert updated.visibility == comment.visibility
      assert updated.ap_id == comment.ap_id
    end
  end

  describe "the bound on a comment body" do
    test "changeset/2 refuses more than 64 KB" do
      changeset =
        Comment.changeset(%Comment{}, %{
          body: String.duplicate("x", 65_537),
          article_id: 1,
          user_id: 1
        })

      assert %{body: [_ | _]} = errors_on(changeset)
    end

    test "remote_changeset/2 refuses it too" do
      changeset =
        Comment.remote_changeset(%Comment{}, %{
          body: String.duplicate("x", 65_537),
          ap_id: "https://remote.example/notes/1",
          article_id: 1,
          remote_actor_id: 1
        })

      assert %{body: [_ | _]} = errors_on(changeset)
    end

    test "exactly 64 KB is accepted" do
      changeset =
        Comment.changeset(%Comment{}, %{
          body: String.duplicate("x", 65_536),
          article_id: 1,
          user_id: 1
        })

      refute Map.has_key?(errors_on(changeset), :body)
    end
  end

  describe "CommentRevision.changeset/2" do
    test "requires a body and a comment" do
      assert %{body: [_ | _], comment_id: [_ | _]} =
               errors_on(CommentRevision.changeset(%CommentRevision{}, %{}))
    end

    test "allows a nil editor, so a deleted account leaves its history standing" do
      {_user, _article, comment} = setup_thread()

      assert {:ok, revision} =
               %CommentRevision{}
               |> CommentRevision.changeset(%{body: "text", comment_id: comment.id})
               |> Repo.insert()

      assert is_nil(revision.editor_id)
    end
  end

  describe "cascades" do
    test "deleting the comment deletes its revisions (ADR 0040's hard delete)" do
      {user, _article, comment} = setup_thread()
      {:ok, _} = Content.update_comment(comment, %{"body" => "edited"}, user)
      assert Content.count_comment_revisions(comment.id) == 1

      Repo.delete!(Repo.get!(Comment, comment.id))

      assert Content.count_comment_revisions(comment.id) == 0
    end
  end
end
