defmodule BaudrateWeb.CommentPermalinkLiveTest do
  @moduledoc """
  `/comments/:id` and the HTML side of `/ap/comments/:id` land on the page
  the comment is on (6B). Comments are paged 20 threads to a page, so the
  `/articles/:slug#comment-N` both used to produce found a comment only
  while it was on page 1.
  """

  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Content
  alias Baudrate.Content.{Board, Comment}
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    author = setup_user("user")

    board =
      %Board{}
      |> Board.changeset(%{name: "Perma", slug: "perma-#{System.unique_integer([:positive])}"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Long thread",
          body: "Body",
          slug: "long-#{System.unique_integer([:positive])}",
          user_id: author.id
        },
        [board.id]
      )

    comments =
      for i <- 1..21 do
        {:ok, comment} =
          Content.create_comment(%{
            "body" => "reply #{i}",
            "article_id" => article.id,
            "user_id" => author.id
          })

        Repo.update_all(
          from(c in Comment, where: c.id == ^comment.id),
          set: [inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], i, :second)]
        )

        comment
      end

    %{author: author, board: board, article: article, last: List.last(comments)}
  end

  test "the permalink redirects to the comment's page and anchor", %{
    conn: conn,
    article: article,
    last: last
  } do
    assert {:error, {:redirect, %{to: to}}} = live(conn, "/comments/#{last.id}")
    assert to == "/articles/#{article.slug}?page=2#comment-#{last.id}"
  end

  test "a comment on page 1 needs no page", %{conn: conn, article: article} do
    first =
      Repo.one!(
        from(c in Comment,
          where: c.article_id == ^article.id,
          order_by: [asc: :inserted_at],
          limit: 1
        )
      )

    assert {:error, {:redirect, %{to: to}}} = live(conn, "/comments/#{first.id}")
    assert to == "/articles/#{article.slug}#comment-#{first.id}"
  end

  test "the fediverse address sends a browser to the same place", %{
    conn: conn,
    article: article,
    last: last
  } do
    conn = get(conn, "/ap/comments/#{last.id}")
    assert redirected_to(conn) == "/articles/#{article.slug}?page=2#comment-#{last.id}"
  end

  describe "refusals answer 404, like an id that never existed" do
    test "a soft-deleted comment", %{conn: conn, author: author, last: last} do
      {:ok, _} = Content.soft_delete_comment(last, deleted_by: author.id)
      assert_raise BaudrateWeb.NotFoundError, fn -> live(conn, "/comments/#{last.id}") end
    end

    test "a comment in a board the reader cannot open", %{conn: conn, board: board, last: last} do
      {:ok, _} = Content.update_board(board, %{min_role_to_view: "user"})
      assert_raise BaudrateWeb.NotFoundError, fn -> live(conn, "/comments/#{last.id}") end
    end

    test "an id that is not a number", %{conn: conn} do
      assert_raise BaudrateWeb.NotFoundError, fn -> live(conn, "/comments/nope") end
    end
  end
end
