defmodule BaudrateWeb.HeldPostsLiveTest do
  @moduledoc """
  `/moderation/held` — posts waiting for review (ADR 0065). The rules are
  `Baudrate.Moderation.HeldPosts`' and are gated in
  `Baudrate.Moderation.HeldPostTest`; this checks the page shows each
  reviewer what is theirs, acts on the id it is sent only inside that scope,
  and says why an approval failed.
  """
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.{Content, Repo}
  alias Baudrate.Moderation.{HeldPost, HeldPosts}
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "hold_first_posts", value: "1"})

    {:ok, board} =
      Content.create_board(%{
        name: "Mine",
        slug: "held-mine-#{System.unique_integer([:positive])}"
      })

    {:ok, conn: conn, board: board, newcomer: setup_user("user")}
  end

  defp hold(author, board, title \\ "Waiting title") do
    {:held, held} =
      Content.submit_article(
        %{
          "title" => title,
          "body" => "Waiting body",
          "slug" => "held-#{System.unique_integer([:positive])}",
          "user_id" => author.id
        },
        [board.id]
      )

    held
  end

  test "a member who reviews nothing is sent away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
             live(log_in_user(conn, setup_user("user")), "/moderation/held")

    assert message =~ "do not moderate"
  end

  test "staff see what is waiting, and approving publishes it", ctx do
    held = hold(ctx.newcomer, ctx.board)
    moderator = setup_user("moderator")

    {:ok, lv, html} = live(log_in_user(ctx.conn, moderator), "/moderation/held")

    assert html =~ "Waiting title"
    assert html =~ "Waiting body"
    assert html =~ "One of the author&#39;s first posts"

    html = lv |> element("#held-post-approve-#{held.id}") |> render_click()

    assert html =~ "Approved and published."
    refute html =~ "Waiting body"
    assert Repo.get_by(Content.Article, title: "Waiting title")
  end

  test "declining keeps the note for the author and shows under Declined", ctx do
    held = hold(ctx.newcomer, ctx.board)
    {:ok, lv, _} = live(log_in_user(ctx.conn, setup_user("moderator")), "/moderation/held")

    html =
      lv
      |> form("#held-post-reject-form-#{held.id}", %{
        "note" => "Please post it in the other board."
      })
      |> render_submit()

    assert html =~ "Declined. The author has been told."

    assert %HeldPost{status: "rejected", review_note: "Please post it in the other board."} =
             Repo.get(HeldPost, held.id)

    {:ok, _lv, html} =
      live(log_in_user(ctx.conn, setup_user("moderator")), "/moderation/held?status=rejected")

    assert html =~ "Please post it in the other board."
  end

  test "a board moderator sees and acts on only their own boards' posts", ctx do
    board_mod = setup_user("user")
    {:ok, _} = Content.add_board_moderator(ctx.board.id, board_mod.id)

    {:ok, other} =
      Content.create_board(%{
        name: "Other",
        slug: "held-other-#{System.unique_integer([:positive])}"
      })

    mine = hold(ctx.newcomer, ctx.board, "In my board")
    theirs = hold(setup_user("user"), other, "In another board")

    {:ok, lv, html} = live(log_in_user(ctx.conn, board_mod), "/moderation/held")

    assert html =~ "In my board"
    refute html =~ "In another board"

    # A forged id for somebody else's post is refused, and changes nothing.
    html = render_click(lv, "approve", %{"id" => to_string(theirs.id)})
    assert html =~ "not yours to review"
    assert Repo.get(HeldPost, theirs.id).status == "pending"

    html = render_submit(lv, "reject", %{"held_post_id" => to_string(theirs.id), "note" => ""})
    assert html =~ "not yours to review"
    assert Repo.get(HeldPost, theirs.id).status == "pending"

    assert HeldPosts.get_pending_for_reviewer(mine.id, board_mod)
  end

  test "an approval that fails says why", ctx do
    held = hold(ctx.newcomer, ctx.board)
    admin = setup_user("admin")

    {:ok, _} =
      Baudrate.Auth.issue_sanction(admin, ctx.newcomer, "silence",
        reason: "Spam",
        expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
      )

    {:ok, lv, _} = live(log_in_user(ctx.conn, setup_user("moderator")), "/moderation/held")
    html = lv |> element("#held-post-approve-#{held.id}") |> render_click()

    assert html =~ "account is restricted"
    assert Repo.get(HeldPost, held.id).status == "pending"
  end

  test "the report queues link to it with the count", ctx do
    hold(ctx.newcomer, ctx.board)
    board_mod = setup_user("user")
    {:ok, _} = Content.add_board_moderator(ctx.board.id, board_mod.id)

    {:ok, _lv, html} = live(log_in_user(ctx.conn, board_mod), "/moderation")
    assert html =~ "1 post waiting for review"
  end
end
