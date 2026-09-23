defmodule BaudrateWeb.Features.CommentsTest do
  use BaudrateWeb.FeatureCase, async: false

  import Ecto.Query, only: [from: 2]

  @moduletag :feature

  feature "authenticated user can post a comment", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "Comment Board"})
    article = create_article(user, board, %{title: "Commentable Article"})

    session
    |> log_in_via_browser(user)
    |> visit("/articles/#{article.slug}")
    |> fill_in(Query.css("#comment_body"), with: "This is a test comment.")
    |> click(Query.button("Post Comment"))
    |> assert_has(Query.text("This is a test comment."))
  end

  feature "guest cannot post comments", %{session: session} do
    user = setup_user("user")
    board = create_board(%{name: "GuestComment Board"})
    article = create_article(user, board, %{title: "Guest Article"})

    session
    |> visit("/articles/#{article.slug}")
    |> assert_has(Query.css("h2", text: "Comments"))
    |> refute_has(Query.css("#comment_body"))
    # Visible, not merely present: a content blocker hides by name.
    |> assert_has(Query.css("#comments-sign-in-link", text: "Sign in to comment", visible: true))
  end

  # The jump crosses a page. The pager moves focus into the list it scrolled
  # to, which put keyboard focus on the comments section's first control while
  # the screen showed the comment the reader asked for.
  feature "the jump to the first new comment lands on it, on its page", %{session: session} do
    author = setup_user("user")
    reader = setup_user("user")
    board = create_board(%{name: "Long Thread Board"})
    article = create_article(author, board, %{title: "Long Thread"})

    long_ago = ~U[2025-01-01 00:00:00Z]

    Baudrate.Repo.update_all(
      from(u in Baudrate.Setup.User, where: u.id == ^reader.id),
      set: [inserted_at: long_ago]
    )

    Baudrate.Repo.insert!(%Baudrate.Content.ArticleRead{
      user_id: reader.id,
      article_id: article.id,
      read_at: ~U[2026-01-01 00:00:00Z]
    })

    comment_at = fn comment, at ->
      Baudrate.Repo.update_all(
        from(c in Baudrate.Content.Comment, where: c.id == ^comment.id),
        set: [inserted_at: at]
      )
    end

    for i <- 1..25 do
      {:ok, c} =
        Baudrate.Content.create_comment(%{
          "body" => "Earlier comment #{i}",
          "article_id" => article.id,
          "user_id" => author.id
        })

      comment_at.(c, DateTime.add(~U[2025-12-01 00:00:00Z], i, :second))
    end

    {:ok, new} =
      Baudrate.Content.create_comment(%{
        "body" => "The comment you have not read",
        "article_id" => article.id,
        "user_id" => author.id
      })

    comment_at.(new, ~U[2026-01-02 00:00:00Z])

    session
    |> log_in_via_browser(reader)
    |> visit("/articles/#{article.slug}")
    |> click(Query.css("#comments-first-new"))
    |> assert_has(Query.css("#comment-new-#{new.id}", text: "New"))

    assert eventually(session, in_view_script(), "comment-#{new.id}", 20)
    assert eventually(session, focus_within_script(), "comment-#{new.id}", 20)
  end

  defp in_view_script do
    """
    const r = document.getElementById(arguments[0]).getBoundingClientRect();
    return r.top >= 0 && r.top < window.innerHeight;
    """
  end

  defp focus_within_script do
    "return document.getElementById(arguments[0]).contains(document.activeElement);"
  end

  defp eventually(_session, _script, _id, 0), do: false

  defp eventually(session, script, id, tries) do
    execute_script(session, script, [id], fn result -> send(self(), {:script, result}) end)

    receive do
      {:script, true} ->
        true

      {:script, _} ->
        Process.send_after(self(), :tick, 100)

        receive do
          :tick -> eventually(session, script, id, tries - 1)
        end
    end
  end
end
