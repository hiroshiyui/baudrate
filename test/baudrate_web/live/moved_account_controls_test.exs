defmodule BaudrateWeb.MovedAccountControlsTest do
  @moduledoc """
  A moved account is read-only (ADR 0025). The context boundary enforces it;
  these tests check that pages do not offer controls that would only fail,
  while still letting the account undo an existing like or boost.
  """

  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.{Content, Repo}
  alias Baudrate.Content.Board
  alias Baudrate.Setup.{Setting, User}

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    author = setup_user("user")
    mover = setup_user("user")

    board =
      %Board{}
      |> Board.changeset(%{name: "Moved", slug: "moved-#{System.unique_integer([:positive])}"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Poll article",
          body: "Body",
          slug: "moved-#{System.unique_integer([:positive])}",
          user_id: author.id
        },
        [board.id],
        poll: %{
          mode: "single",
          options: [%{text: "Yes", position: 0}, %{text: "No", position: 1}]
        }
      )

    {:ok, comment} =
      Content.create_comment(%{body: "A comment", article_id: article.id, user_id: author.id})

    %{conn: conn, author: author, mover: mover, board: board, article: article, comment: comment}
  end

  defp move!(user) do
    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [moved_to: "https://new.example/users/mover"]
    )

    Repo.reload!(user)
  end

  test "an active account gets the like, boost, vote and forward controls",
       %{conn: conn, mover: user, article: article} do
    {:ok, lv, _html} = live(log_in_user(conn, user), "/articles/#{article.slug}")

    assert has_element?(lv, "#article-like-toggle")
    assert has_element?(lv, "#article-boost-toggle")
    assert has_element?(lv, "#poll-vote-form")
    assert has_element?(lv, ".comment-like-button")
    assert has_element?(lv, ".comment-forward-button")
  end

  test "a moved account sees counts and poll results instead of controls",
       %{conn: conn, mover: mover, article: article} do
    mover = move!(mover)
    {:ok, lv, _html} = live(log_in_user(conn, mover), "/articles/#{article.slug}")

    refute has_element?(lv, "#article-like-toggle")
    refute has_element?(lv, "#article-boost-toggle")
    assert has_element?(lv, ".article-like-count")
    assert has_element?(lv, ".article-boost-count")
    refute has_element?(lv, "#poll-vote-form")
    assert has_element?(lv, ".article-poll-results")
    refute has_element?(lv, "#article-menu-forward")
    refute has_element?(lv, ".comment-like-button")
    refute has_element?(lv, ".comment-boost-button")
    refute has_element?(lv, ".comment-forward-button")
    refute has_element?(lv, ".comment-reply-button")
    refute has_element?(lv, "#comment-form")
  end

  test "a moved account can still undo an existing like and boost",
       %{conn: conn, mover: mover, article: article, comment: comment} do
    {:ok, _} = Content.toggle_article_like(mover.id, article.id)
    {:ok, _} = Content.toggle_article_boost(mover.id, article.id)
    {:ok, _} = Content.toggle_comment_like(mover.id, comment.id)
    mover = move!(mover)

    {:ok, lv, _html} = live(log_in_user(conn, mover), "/articles/#{article.slug}")

    assert has_element?(lv, "#article-like-toggle[aria-pressed=true]")
    assert has_element?(lv, "#article-boost-toggle[aria-pressed=true]")
    assert has_element?(lv, ".comment-like-button[aria-pressed=true]")
    refute has_element?(lv, ".comment-boost-button")

    lv |> element("#article-like-toggle") |> render_click()
    refute has_element?(lv, "#article-like-toggle")
    assert has_element?(lv, ".article-like-count")
  end

  test "board listings hide like and boost for a moved account",
       %{conn: conn, mover: mover, board: board, article: article} do
    {:ok, lv, _html} = live(log_in_user(conn, mover), "/boards/#{board.slug}")
    assert has_element?(lv, "#board-article-like-#{article.id}")

    mover = move!(mover)
    {:ok, lv, _html} = live(log_in_user(build_conn(), mover), "/boards/#{board.slug}")
    refute has_element?(lv, "#board-article-like-#{article.id}")
    refute has_element?(lv, "#board-article-boost-#{article.id}")
  end
end
