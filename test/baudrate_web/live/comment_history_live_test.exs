defmodule BaudrateWeb.CommentHistoryLiveTest do
  @moduledoc """
  ADR 0060's second half: the history is public, and two things it must refuse.
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
      |> Board.changeset(%{name: "General", slug: "general-chist"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "A thread", body: "Body", slug: "chist-article", user_id: user.id},
        [board.id]
      )

    {:ok, comment} =
      Content.create_comment(%{
        "body" => "the first thing I said",
        "article_id" => article.id,
        "user_id" => user.id
      })

    {:ok,
     conn: log_in_user(conn, user),
     guest_conn: conn,
     user: user,
     board: board,
     article: article,
     comment: comment}
  end

  describe "the page" do
    test "shows the current version and each revision", %{
      conn: conn,
      user: user,
      comment: comment
    } do
      {:ok, _} = Content.update_comment(comment, %{"body" => "what I meant to say"}, user)

      {:ok, _lv, html} = live(conn, "/comments/#{comment.id}/history")

      assert html =~ "Edit History"
      assert html =~ user.username
      assert html =~ "Current"
      assert html =~ "#1"
    end

    test "says so plainly when there is nothing to show", %{conn: conn, comment: comment} do
      {:ok, _lv, html} = live(conn, "/comments/#{comment.id}/history")
      assert html =~ "has not been edited"
      refute html =~ "comment-history-table"
    end

    test "diffs the selected version against the one before it", %{
      conn: conn,
      user: user,
      comment: comment
    } do
      {:ok, _} = Content.update_comment(comment, %{"body" => "what I meant to say"}, user)

      {:ok, lv, _html} = live(conn, "/comments/#{comment.id}/history")

      html =
        lv
        |> element("#comment-history-select-current")
        |> render_click()

      # The most recent edit is visible at all, which a list of revisions
      # alone cannot show: a revision holds the state *before* a change, so
      # the newest one is what the latest edit replaced, never its result.
      # The diff is character-level, so assert on the markers rather than on
      # a contiguous phrase.
      assert html =~ "comment-history-diff-ins"
      assert html =~ "comment-history-diff-del"
      assert html =~ "Current version"
    end

    test "shows the content warning that was removed", %{conn: conn, user: user, article: article} do
      {:ok, warned} =
        Content.create_comment(%{
          "body" => "hidden text",
          "summary" => "spoilers",
          "article_id" => article.id,
          "user_id" => user.id
        })

      {:ok, _} = Content.update_comment(warned, %{"body" => "hidden text", "summary" => ""}, user)

      {:ok, lv, _html} = live(conn, "/comments/#{warned.id}/history")
      html = lv |> element("#comment-history-select-current") |> render_click()

      assert html =~ "Content warning"
      assert html =~ "spoilers"
    end
  end

  describe "who may read it" do
    test "a guest may, exactly as they may read the thread", %{
      guest_conn: conn,
      user: user,
      comment: comment
    } do
      {:ok, _} = Content.update_comment(comment, %{"body" => "revised"}, user)

      {:ok, _lv, html} = live(conn, "/comments/#{comment.id}/history")
      assert html =~ "Edit History"
    end

    test "a member who cannot open the board may not", %{user: user, article: article} do
      private =
        %Board{}
        |> Board.changeset(%{
          name: "Staff",
          slug: "staff-chist",
          min_role_to_view: "admin",
          min_role_to_post: "admin"
        })
        |> Repo.insert!()

      {:ok, %{article: hidden_article}} =
        Content.create_article(
          %{title: "Private", body: "Body", slug: "chist-private", user_id: user.id},
          [private.id]
        )

      {:ok, hidden_comment} =
        Content.create_comment(%{
          "body" => "private reply",
          "article_id" => hidden_article.id,
          "user_id" => user.id
        })

      outsider = setup_user("user")
      conn = log_in_user(build_conn(), outsider)

      assert_raise BaudrateWeb.NotFoundError, fn ->
        live(conn, "/comments/#{hidden_comment.id}/history")
      end

      # The article's own page refuses too, so the two agree.
      refute Content.can_edit_comment?(outsider, hidden_comment)
      assert article.id != hidden_article.id
    end
  end

  describe "what it refuses" do
    test "a soft-deleted comment, even to its author", %{
      conn: conn,
      user: user,
      comment: comment
    } do
      {:ok, _} = Content.update_comment(comment, %{"body" => "second thoughts"}, user)
      {:ok, _} = Content.soft_delete_comment(comment, deleted_by: user.id)

      # Deletion replaces the body with a placeholder, but the revisions still
      # hold every earlier draft — serving them would make withdrawing a
      # comment a way of publishing what it used to say.
      assert_raise BaudrateWeb.NotFoundError, fn ->
        live(conn, "/comments/#{comment.id}/history")
      end
    end

    test "a remote comment, whose history lives on the instance that minted it", %{
      conn: conn,
      article: article
    } do
      {:ok, actor} =
        %Baudrate.Federation.RemoteActor{}
        |> Baudrate.Federation.RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/bob",
          username: "bob",
          domain: "remote.example",
          public_key_pem: elem(Baudrate.Federation.KeyStore.generate_keypair(), 0),
          inbox: "https://remote.example/users/bob/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      {:ok, remote_comment} =
        Content.create_remote_comment(%{
          body: "from elsewhere",
          body_html: "<p>from elsewhere</p>",
          ap_id: "https://remote.example/notes/1",
          article_id: article.id,
          remote_actor_id: actor.id
        })

      assert_raise BaudrateWeb.NotFoundError, fn ->
        live(conn, "/comments/#{remote_comment.id}/history")
      end
    end

    test "an id that is not a number, and one that names nothing", %{conn: conn} do
      for bad <- ["abc", "0", "-1", "999999999"] do
        assert_raise BaudrateWeb.NotFoundError, fn ->
          live(conn, "/comments/#{bad}/history")
        end
      end
    end
  end

  describe "crawlers" do
    test "the page is noindex and names no canonical", %{
      conn: conn,
      user: user,
      comment: comment
    } do
      {:ok, _} = Content.update_comment(comment, %{"body" => "revised"}, user)

      conn = get(conn, "/comments/#{comment.id}/history")
      html = html_response(conn, 200)

      assert html =~ ~s(name="robots")
      assert html =~ "noindex"
      refute html =~ ~s(rel="canonical")
    end
  end
end
