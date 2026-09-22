defmodule BaudrateWeb.DraftsLiveTest do
  @moduledoc """
  The web half of server-side drafts: the composer that writes them and the
  page that lists them.

  The context gate is `Baudrate.Content.DraftTest`; what is tested here is the
  wiring only a mounted LiveView can show — when a draft is written, when it
  is restored, and when restoring it would be wrong.
  """
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")

    board =
      %Board{}
      |> Board.changeset(%{name: "General", slug: "general-drafts"})
      |> Repo.insert!()

    {:ok, conn: log_in_user(conn, user), user: user, board: board}
  end

  # The composer debounces server-side with `Process.send_after/3`. Sending the
  # message is the same thing the timer does, without a two-second sleep in
  # every test.
  defp flush_autosave(lv) do
    send(lv.pid, :autosave_draft)
    render(lv)
  end

  defp type(lv, attrs) do
    render_change(lv, "validate", %{"article" => Map.merge(%{"title" => "", "body" => ""}, attrs)})
  end

  describe "the composer writes a draft" do
    test "after typing, without being asked", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      type(lv, %{"title" => "Half a thought", "body" => "still working on it"})
      flush_autosave(lv)

      assert [draft] = Content.list_drafts(user.id)
      assert draft.title == "Half a thought"
      assert draft.body == "still working on it"
    end

    test "and keeps writing into the same row rather than piling up", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      type(lv, %{"title" => "First", "body" => "a"})
      flush_autosave(lv)
      type(lv, %{"title" => "First", "body" => "ab"})
      flush_autosave(lv)
      type(lv, %{"title" => "First", "body" => "abc"})
      flush_autosave(lv)

      assert [draft] = Content.list_drafts(user.id)
      assert draft.body == "abc"
    end

    test "but never for an empty composer", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      type(lv, %{"title" => "  ", "body" => ""})
      flush_autosave(lv)

      assert Content.list_drafts(user.id) == []
    end
  end

  describe "the composer restores a draft" do
    test "the most recent one, on a bare /articles/new", %{conn: conn, user: user} do
      {:ok, _} = Content.save_draft(user.id, %{"title" => "Left off here", "body" => "the body"})

      {:ok, _lv, html} = live(conn, "/articles/new")

      assert html =~ "Left off here"
      assert html =~ "Picked up where you left off"
    end

    test "a named one, from /drafts", %{conn: conn, user: user} do
      {:ok, _older} = Content.save_draft(user.id, %{"title" => "Older", "body" => "a"})
      {:ok, wanted} = Content.save_draft(user.id, %{"title" => "The one I picked", "body" => "b"})

      {:ok, _lv, html} = live(conn, "/articles/new?draft=#{wanted.id}")

      assert html =~ "The one I picked"
    end

    test "never somebody else's, even when the id is right", %{conn: conn} do
      stranger = setup_user("user")
      {:ok, theirs} = Content.save_draft(stranger.id, %{"title" => "Not yours", "body" => "x"})

      {:ok, _lv, html} = live(conn, "/articles/new?draft=#{theirs.id}")

      refute html =~ "Not yours"
      refute html =~ "Picked up where you left off"
    end

    test "never over content shared into the composer", %{conn: conn, user: user} do
      {:ok, _} = Content.save_draft(user.id, %{"title" => "An old draft", "body" => "old"})

      # The PWA share target opens the composer already holding what was
      # shared. An old draft landing on top of it would discard the thing the
      # member is actually trying to post.
      {:ok, lv, html} = live(conn, "/articles/new?title=Shared&text=from+another+app")

      assert html =~ "Shared"
      refute html =~ "An old draft"

      # The fields are only half of it. Adopting the draft would also mean the
      # composer autosaves the shared post *into* it, overwriting the older
      # work — so the draft must not be adopted at all, not merely lose the
      # race for the title field.
      refute html =~ "Picked up where you left off"

      send(lv.pid, :autosave_draft)
      render(lv)

      titles = user.id |> Content.list_drafts() |> Enum.map(& &1.title)
      assert "An old draft" in titles
    end

    test "never when the composer was opened from a board", %{
      conn: conn,
      user: user,
      board: board
    } do
      {:ok, _} = Content.save_draft(user.id, %{"title" => "Unrelated draft", "body" => "x"})

      # "Post in #general" is a statement about what the member is doing now;
      # an unrelated draft addressed to other boards is a non-sequitur.
      {:ok, _lv, html} = live(conn, "/boards/#{board.slug}/articles/new")

      refute html =~ "Unrelated draft"
    end

    # No test resumed a draft with a board chosen, and the composer crashed on
    # every one: `Content.get_board/1` answers `{:ok, board}`, and the resume
    # treated the tuple as the board.
    test "with the boards it had, and without one the member has lost", %{
      conn: conn,
      user: user,
      board: board
    } do
      closed =
        %Board{}
        |> Board.changeset(%{
          name: "Staff room",
          slug: "staff-room-drafts",
          min_role_to_post: "moderator"
        })
        |> Repo.insert!()

      {:ok, draft} =
        Content.save_draft(user.id, %{
          "title" => "Boarded draft",
          "body" => "x",
          "board_ids" => [board.id, closed.id, 999_999_999]
        })

      {:ok, _lv, html} = live(conn, "/articles/new?draft=#{draft.id}")

      assert html =~ "Boarded draft"
      assert html =~ ~s(name="board_ids[]" value="#{board.id}")
      refute html =~ ~s(value="#{closed.id}")
    end

    test "not a blank one left behind by opening the composer", %{conn: conn, user: user} do
      {:ok, _} = Content.save_draft(user.id, %{"title" => "", "body" => ""})

      {:ok, _lv, html} = live(conn, "/articles/new")

      refute html =~ "Picked up where you left off"
    end
  end

  describe "posting" do
    test "removes the draft it came from", %{conn: conn, user: user, board: board} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      type(lv, %{"title" => "Ready to post", "body" => "the body"})
      flush_autosave(lv)
      assert [_] = Content.list_drafts(user.id)

      lv
      |> form("#article-new-form", %{
        "article" => %{"title" => "Ready to post", "body" => "the body"}
      })
      |> render_submit(%{"board_ids" => [to_string(board.id)]})

      assert Content.list_drafts(user.id) == []
    end
  end

  describe "posts waiting for review (ADR 0065)" do
    setup %{user: user, board: board} do
      Repo.insert!(%Setting{key: "hold_first_posts", value: "3"})

      {:held, held} =
        Content.submit_article(
          %{
            "title" => "Held for review",
            "body" => "The text I wrote",
            "slug" => "held-drafts-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      %{held: held}
    end

    test "are listed with what was written, and can be withdrawn", %{conn: conn, held: held} do
      {:ok, lv, html} = live(conn, "/drafts")

      assert html =~ "Waiting for review"
      assert html =~ "Held for review"
      assert html =~ "The text I wrote"

      html = lv |> element("#held-withdraw-#{held.id}") |> render_click()

      assert html =~ "Withdrawn."
      refute Repo.get(Baudrate.Moderation.HeldPost, held.id)
    end

    test "a declined one shows the moderator's note and cannot be erased", %{
      conn: conn,
      held: held
    } do
      {:ok, _} =
        Baudrate.Moderation.HeldPosts.reject(held, setup_user("admin"), "Wrong board, sorry.")

      {:ok, lv, html} = live(conn, "/drafts")

      assert html =~ "Declined"
      assert html =~ "Wrong board, sorry."
      refute has_element?(lv, "#held-withdraw-#{held.id}")

      # A forged withdrawal of a declined post changes nothing.
      render_click(lv, "withdraw_held", %{"id" => to_string(held.id)})
      assert Repo.get(Baudrate.Moderation.HeldPost, held.id)
    end

    test "nobody else's are listed", %{conn: conn, held: held} do
      {:ok, _lv, html} = live(log_in_user(conn, setup_user("user")), "/drafts")

      refute html =~ "Held for review"
      refute html =~ "held-#{held.id}"
    end
  end

  describe "the drafts page" do
    test "lists the member's own and nobody else's", %{conn: conn, user: user} do
      stranger = setup_user("user")
      {:ok, _} = Content.save_draft(user.id, %{"title" => "Mine to finish", "body" => "a"})
      {:ok, _} = Content.save_draft(stranger.id, %{"title" => "Theirs entirely", "body" => "b"})

      {:ok, _lv, html} = live(conn, "/drafts")

      assert html =~ "Mine to finish"
      refute html =~ "Theirs entirely"
    end

    test "says so plainly when there is nothing", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/drafts")
      assert html =~ "You have no drafts"
    end

    test "falls back to the body when a draft was never titled", %{conn: conn, user: user} do
      {:ok, _} = Content.save_draft(user.id, %{"body" => "a first line nobody titled"})

      {:ok, _lv, html} = live(conn, "/drafts")

      assert html =~ "a first line nobody titled"
    end

    test "deletes one the member owns", %{conn: conn, user: user} do
      {:ok, draft} = Content.save_draft(user.id, %{"title" => "Going away", "body" => "a"})

      {:ok, lv, _html} = live(conn, "/drafts")
      html = lv |> element("#draft-delete-#{draft.id}") |> render_click()

      refute html =~ "Going away"
      assert Content.list_drafts(user.id) == []
    end

    test "a delete aimed at somebody else's draft does nothing", %{conn: conn} do
      stranger = setup_user("user")
      {:ok, theirs} = Content.save_draft(stranger.id, %{"title" => "Not yours", "body" => "x"})

      {:ok, lv, _html} = live(conn, "/drafts")
      render_click(lv, "delete", %{"id" => to_string(theirs.id)})

      assert [_] = Content.list_drafts(stranger.id)
    end

    test "needs a signed-in member", %{} do
      assert {:error, {:redirect, %{to: "/login" <> _}}} =
               live(Phoenix.ConnTest.build_conn(), "/drafts")
    end
  end

  describe "crawlers" do
    test "the page refuses indexing and names no canonical", %{conn: conn} do
      conn = get(conn, "/drafts")
      html = html_response(conn, 200)

      assert html =~ "noindex"
      refute html =~ ~s(rel="canonical")
    end
  end
end
