defmodule Baudrate.Content.ArticleRevisionTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{Board, ArticleRevision}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name) do
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
    slug = "board-#{System.unique_integer([:positive])}"

    %Board{}
    |> Board.changeset(%{name: "Board", slug: slug})
    |> Repo.insert!()
  end

  defp create_article(user, board) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Original Title",
          body: "Original body content",
          slug: "rev-test-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end

  describe "create_article_revision/2" do
    test "creates a revision snapshot of the article" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      assert {:ok, %ArticleRevision{} = revision} =
               Content.create_article_revision(article, user)

      assert revision.title == "Original Title"
      assert revision.body == "Original body content"
      assert revision.article_id == article.id
      assert revision.editor_id == user.id
    end

    test "creates a revision with nil editor" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      assert {:ok, %ArticleRevision{} = revision} =
               Content.create_article_revision(article, nil)

      assert revision.editor_id == nil
    end
  end

  describe "update_article/3 with editor" do
    test "creates a revision before applying the update" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      assert {:ok, updated} =
               Content.update_article(article, %{title: "Updated Title", body: "Updated body"}, user)

      assert updated.title == "Updated Title"
      assert updated.body == "Updated body"

      revisions = Content.list_article_revisions(article.id)
      assert length(revisions) == 1

      [revision] = revisions
      assert revision.title == "Original Title"
      assert revision.body == "Original body content"
      assert revision.editor_id == user.id
    end

    test "does not create a revision when editor is nil (2-arity)" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      assert {:ok, _updated} =
               Content.update_article(article, %{title: "Silent Update", body: "No revision"})

      assert Content.count_article_revisions(article.id) == 0
    end

    test "accumulates revisions across multiple edits" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      {:ok, article2} =
        Content.update_article(article, %{title: "Second", body: "Second body"}, user)

      {:ok, _article3} =
        Content.update_article(article2, %{title: "Third", body: "Third body"}, user)

      revisions = Content.list_article_revisions(article.id)
      assert length(revisions) == 2

      # Newest first
      [rev2, rev1] = revisions
      assert rev2.title == "Second"
      assert rev1.title == "Original Title"
    end
  end

  describe "list_article_revisions/1" do
    test "returns revisions ordered newest first" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      {:ok, a2} = Content.update_article(article, %{title: "V2", body: "body2"}, user)
      {:ok, _a3} = Content.update_article(a2, %{title: "V3", body: "body3"}, user)

      revisions = Content.list_article_revisions(article.id)
      assert length(revisions) == 2
      assert hd(revisions).title == "V2"
      assert List.last(revisions).title == "Original Title"
    end

    test "preloads editor" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      {:ok, _} = Content.update_article(article, %{title: "Edited", body: "new"}, user)

      [revision] = Content.list_article_revisions(article.id)
      assert revision.editor.username == user.username
    end
  end

  describe "count_article_revisions/1" do
    test "returns 0 for article with no revisions" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      assert Content.count_article_revisions(article.id) == 0
    end

    test "returns correct count" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      {:ok, a2} = Content.update_article(article, %{title: "V2", body: "b2"}, user)
      {:ok, _a3} = Content.update_article(a2, %{title: "V3", body: "b3"}, user)

      assert Content.count_article_revisions(article.id) == 2
    end
  end

  describe "get_article_revision!/1" do
    test "fetches a revision by ID with editor preloaded" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      {:ok, _} = Content.update_article(article, %{title: "Edited", body: "new"}, user)
      [revision] = Content.list_article_revisions(article.id)

      fetched = Content.get_article_revision!(revision.id)
      assert fetched.id == revision.id
      assert fetched.editor.id == user.id
    end
  end
end
