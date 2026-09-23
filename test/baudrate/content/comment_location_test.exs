defmodule Baudrate.Content.CommentLocationTest do
  @moduledoc """
  Where a comment is (6B): the page `paginate_comments_for_article/3` puts
  it on, and what a reader has not seen yet.

  Every link to a comment — notifications, "jump to the first new comment",
  the fediverse redirect, the permalink — is built from
  `Content.comment_location/2`, and a bare `#comment-N` only ever worked on
  page 1. So the page it answers is checked against the paginator itself,
  not against arithmetic written again in the test.
  """

  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{ArticleRead, BoardRead, Comment}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    author = create_user()
    board = create_board()
    article = create_article(author, board)
    %{author: author, board: board, article: article}
  end

  describe "comment_location/2" do
    test "a root comment is on the page the paginator puts it on", %{
      author: author,
      article: article
    } do
      roots = for i <- 1..45, do: comment!(article, author, nil, i)

      for {comment, expected_page} <- [
            {Enum.at(roots, 0), 1},
            {Enum.at(roots, 19), 1},
            {Enum.at(roots, 20), 2},
            {Enum.at(roots, 44), 3}
          ] do
        assert {^expected_page, anchor} = Content.comment_location(comment, nil)
        assert anchor == "comment-#{comment.id}"
        assert comment.id in page_ids(article, nil, expected_page)
      end
    end

    test "a reply four levels deep is on its root's page", %{author: author, article: article} do
      roots = for i <- 1..25, do: comment!(article, author, nil, i)
      root = List.last(roots)

      deepest =
        Enum.reduce(1..4, root, fn i, parent -> comment!(article, author, parent, 100 + i) end)

      assert {2, "comment-#{deepest.id}"} == Content.comment_location(deepest, nil)
      assert deepest.id in page_ids(article, nil, 2)
    end

    test "a blocked author's threads move the page exactly as the paginator does", %{
      author: author,
      article: article
    } do
      viewer = create_user()
      blocked = create_user()
      {:ok, _} = Baudrate.Auth.block_user(viewer, blocked)

      # Twenty threads by the blocked author come first, so for the viewer the
      # 21st root is on page 1 while for a guest it is on page 2.
      for i <- 1..20, do: comment!(article, blocked, nil, i)
      target = comment!(article, author, nil, 21)

      assert {2, _} = Content.comment_location(target, nil)
      assert {1, _} = Content.comment_location(target, viewer)
      assert target.id in page_ids(article, viewer, 1)
    end

    test "a comment whose thread the viewer cannot see has no location", %{
      author: author,
      article: article
    } do
      viewer = create_user()
      blocked = create_user()
      {:ok, _} = Baudrate.Auth.block_user(viewer, blocked)

      root = comment!(article, blocked, nil, 1)
      reply = comment!(article, author, root, 2)

      assert Content.comment_location(reply, viewer) == nil
      assert {1, _} = Content.comment_location(reply, nil)
    end
  end

  describe "last_read_at/2" do
    test "is nil for a guest", %{article: article} do
      assert Content.last_read_at(nil, article) == nil
    end

    test "is registration time before any visit", %{article: article} do
      reader = create_user()
      assert Content.last_read_at(reader, article) == reader.inserted_at
    end

    test "is the latest of the visit and a board's mark-all-as-read", %{
      board: board,
      article: article
    } do
      reader = create_user()
      visit = DateTime.add(reader.inserted_at, 3600, :second)
      floor = DateTime.add(reader.inserted_at, 7200, :second)

      Repo.insert!(%ArticleRead{user_id: reader.id, article_id: article.id, read_at: visit})
      assert Content.last_read_at(reader, article) == visit

      Repo.insert!(%BoardRead{user_id: reader.id, board_id: board.id, read_at: floor})
      assert Content.last_read_at(reader, article) == floor
    end
  end

  describe "first_comment_since/3" do
    test "is the earliest unseen comment by somebody else", %{author: author, article: article} do
      reader = create_user()
      since = ~U[2026-01-01 00:00:00Z]

      _old = comment!(article, author, nil, 0, ~U[2025-12-31 00:00:00Z])
      _own = comment!(article, reader, nil, 1, ~U[2026-01-02 00:00:00Z])
      first = comment!(article, author, nil, 2, ~U[2026-01-03 00:00:00Z])
      _later = comment!(article, author, nil, 3, ~U[2026-01-04 00:00:00Z])

      assert %Comment{id: id} = Content.first_comment_since(article, reader, since)
      assert id == first.id
    end

    test "skips deleted comments and blocked authors", %{author: author, article: article} do
      reader = create_user()
      blocked = create_user()
      {:ok, _} = Baudrate.Auth.block_user(reader, blocked)
      since = ~U[2026-01-01 00:00:00Z]

      deleted = comment!(article, author, nil, 1, ~U[2026-01-02 00:00:00Z])
      {:ok, _} = Content.soft_delete_comment(deleted, deleted_by: author.id)
      _hidden = comment!(article, blocked, nil, 2, ~U[2026-01-03 00:00:00Z])

      assert Content.first_comment_since(article, reader, since) == nil
    end

    test "is nil for a guest", %{article: article} do
      assert Content.first_comment_since(article, nil, ~U[2026-01-01 00:00:00Z]) == nil
    end
  end

  # --- helpers ---

  defp page_ids(article, viewer, page) do
    Content.paginate_comments_for_article(article, viewer, page: page).comments
    |> Enum.map(& &1.id)
  end

  # Comments get explicit, increasing timestamps: the paginator orders by
  # `inserted_at`, and rows inserted within one second would tie.
  defp comment!(article, user, parent, n, at \\ nil) do
    at = at || DateTime.add(~U[2026-01-01 00:00:00Z], n * 60, :second)

    comment =
      %Comment{}
      |> Comment.changeset(%{
        "body" => "comment #{n}",
        "body_html" => "<p>comment #{n}</p>",
        "article_id" => article.id,
        "user_id" => user.id,
        "parent_id" => parent && parent.id
      })
      |> Repo.insert!()

    from(c in Comment, where: c.id == ^comment.id)
    |> Repo.update_all(set: [inserted_at: at])

    %{comment | inserted_at: at}
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

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
    %Content.Board{}
    |> Content.Board.changeset(%{
      name: "Test",
      slug: "test-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp create_article(user, board) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Test Article",
          body: "Body",
          slug: "art-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end
end
