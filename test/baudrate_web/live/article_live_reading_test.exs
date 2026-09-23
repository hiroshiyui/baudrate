defmodule BaudrateWeb.ArticleLiveReadingTest do
  @moduledoc """
  Reading a thread (6B): the comment count, what is new since the reader's
  last visit, the jump to the first new comment, and the prompt a guest is
  shown where the comment form would be.
  """

  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Content
  alias Baudrate.Content.{ArticleRead, Board, Comment}
  alias Baudrate.Setup.Setting

  setup do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    author = setup_user("user")

    board =
      %Board{}
      |> Board.changeset(%{
        name: "Reading",
        slug: "reading-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    article = create_article(author, [board])
    %{author: author, board: board, article: article}
  end

  describe "the comments heading" do
    test "counts every comment on the article, not the ones on this page", %{
      conn: conn,
      author: author,
      article: article
    } do
      roots = for i <- 1..25, do: comment!(article, author, nil, i)
      _reply = comment!(article, author, hd(roots), 30)

      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")
      assert has_element?(lv, "#comments-total", "(26)")

      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}?page=2")
      assert has_element?(lv, "#comments-total", "(26)")
    end
  end

  describe "new since your last visit" do
    test "marks comments after the last visit, and not the reader's own", %{
      conn: conn,
      author: author,
      article: article
    } do
      reader = long_standing_member()
      read!(reader, article, ~U[2026-01-01 00:00:00Z])

      old = comment!(article, author, nil, 1, ~U[2025-12-31 00:00:00Z])
      new = comment!(article, author, nil, 2, ~U[2026-01-02 00:00:00Z])
      own = comment!(article, reader, nil, 3, ~U[2026-01-03 00:00:00Z])

      {:ok, lv, _html} = live(log_in_user(conn, reader), "/articles/#{article.slug}")

      assert has_element?(lv, "#comment-new-#{new.id}", "New")
      assert has_element?(lv, "#comment-#{new.id}.comment-new")
      refute has_element?(lv, "#comment-new-#{old.id}")
      refute has_element?(lv, "#comment-new-#{own.id}")
    end

    test "the visit is recorded, so the same comments are not new next time", %{
      conn: conn,
      author: author,
      article: article
    } do
      reader = long_standing_member()
      read!(reader, article, ~U[2026-01-01 00:00:00Z])
      new = comment!(article, author, nil, 1, ~U[2026-01-02 00:00:00Z])
      conn = log_in_user(conn, reader)

      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")
      assert has_element?(lv, "#comment-new-#{new.id}")

      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")
      refute has_element?(lv, "#comment-new-#{new.id}")
      refute has_element?(lv, "#comments-first-new")
    end

    test "the jump link finds the first new comment on a later page", %{
      conn: conn,
      author: author,
      article: article
    } do
      reader = long_standing_member()
      read!(reader, article, ~U[2026-01-01 00:00:00Z])

      for i <- 1..25, do: comment!(article, author, nil, i, ~U[2025-12-01 00:00:00Z])
      first_new = comment!(article, author, nil, 26, ~U[2026-01-02 00:00:00Z])
      _second_new = comment!(article, author, nil, 27, ~U[2026-01-03 00:00:00Z])

      {:ok, lv, _html} = live(log_in_user(conn, reader), "/articles/#{article.slug}")

      assert has_element?(
               lv,
               ~s|#comments-first-new[href="/articles/#{article.slug}?page=2#comment-#{first_new.id}"]|
             )

      lv |> element("#comments-first-new") |> render_click()
      # The test harness records a patch without its fragment.
      assert_patch(lv, "/articles/#{article.slug}?page=2")
      assert has_element?(lv, "#comment-new-#{first_new.id}")
    end

    test "a guest sees no markers and no jump link", %{author: author, article: article} do
      comment!(article, author, nil, 1)

      {:ok, lv, _html} = live(build_conn(), "/articles/#{article.slug}")
      refute has_element?(lv, ".comment-new")
      refute has_element?(lv, "#comments-first-new")
    end
  end

  describe "a guest's prompt to join in" do
    test "is shown, and brings them back to the article", %{article: article} do
      {:ok, lv, _html} = live(build_conn(), "/articles/#{article.slug}")

      assert has_element?(
               lv,
               ~s|#comments-sign-in-link[href="/login?return_to=%2Farticles%2F#{article.slug}"]|,
               "Sign in to comment"
             )
    end

    test "is not shown to a signed-in member", %{conn: conn, article: article} do
      {:ok, lv, _html} = live(log_in_user(conn, setup_user("user")), "/articles/#{article.slug}")
      refute has_element?(lv, "#comments-sign-in-prompt")
    end

    test "is not shown on a locked thread", %{article: article} do
      Repo.update_all(from(a in Content.Article, where: a.id == ^article.id), set: [locked: true])

      {:ok, lv, _html} = live(build_conn(), "/articles/#{article.slug}")
      refute has_element?(lv, "#comments-sign-in-prompt")
    end

    # Signing in would not give a member a comment form there, so offering
    # one would be a promise the next page breaks.
    test "is not shown where only staff may post", %{author: author} do
      staff_board =
        %Board{}
        |> Board.changeset(%{
          name: "Staff posts",
          slug: "staff-#{System.unique_integer([:positive])}",
          min_role_to_post: "moderator"
        })
        |> Repo.insert!()

      article = create_article(author, [staff_board])

      {:ok, lv, _html} = live(build_conn(), "/articles/#{article.slug}")
      refute has_element?(lv, "#comments-sign-in-prompt")
    end

    test "offers registration unless it is by invitation only", %{article: article} do
      {:ok, lv, _html} = live(build_conn(), "/articles/#{article.slug}")
      assert has_element?(lv, "#comments-register-link")

      Baudrate.Setup.set_setting("registration_mode", "invite_only")

      {:ok, lv, _html} = live(build_conn(), "/articles/#{article.slug}")
      assert has_element?(lv, "#comments-sign-in-link")
      refute has_element?(lv, "#comments-register-link")
    end
  end

  # --- helpers ---

  defp create_article(author, boards) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "A thread",
          body: "Opening post",
          slug: "thread-#{System.unique_integer([:positive])}",
          user_id: author.id
        },
        Enum.map(boards, & &1.id)
      )

    article
  end

  # Registration is part of the floor — nothing written before someone
  # joined is new to them — so a reader in these tests joined long ago.
  defp long_standing_member do
    user = setup_user("user")
    at = ~U[2025-01-01 00:00:00Z]

    Repo.update_all(from(u in Baudrate.Setup.User, where: u.id == ^user.id),
      set: [inserted_at: at]
    )

    %{user | inserted_at: at}
  end

  defp read!(user, article, at) do
    Repo.insert!(%ArticleRead{user_id: user.id, article_id: article.id, read_at: at})
  end

  defp comment!(article, user, parent, n, at \\ nil) do
    at = at || DateTime.add(~U[2025-06-01 00:00:00Z], n * 60, :second)

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

    # Distinct seconds as well as distinct times: the paginator orders by
    # `inserted_at` and the id breaks a tie.
    at = DateTime.add(at, n, :second)
    Repo.update_all(from(c in Comment, where: c.id == ^comment.id), set: [inserted_at: at])
    %{comment | inserted_at: at}
  end
end
