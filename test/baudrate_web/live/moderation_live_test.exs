defmodule BaudrateWeb.ModerationLiveTest do
  @moduledoc """
  The board moderators' queue (`/moderation`, Phase 1B): it must show a
  moderator exactly the reports about their own boards, and refuse every
  action on anything else.
  """
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.{Content, Moderation, Repo}
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  defp board(name) do
    {:ok, board} =
      Content.create_board(%{name: name, slug: "#{name}-#{System.unique_integer([:positive])}"})

    board
  end

  defp article_in(board, author, title \\ "Reported article") do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: title,
          body: "Body of #{title}",
          slug: "art-#{System.unique_integer([:positive])}",
          user_id: author.id
        },
        [board.id]
      )

    article
  end

  defp report_article(article, reporter, reason \\ "Spam") do
    {:ok, report} =
      Moderation.create_report(%{
        category: "spam",
        reason: reason,
        reporter_id: reporter.id,
        article_id: article.id
      })

    report
  end

  defp moderator_of(board) do
    user = setup_user("user")
    {:ok, _} = Content.add_board_moderator(board.id, user.id)
    user
  end

  test "a member who moderates no board is sent away", %{conn: conn} do
    user = setup_user("user")

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
             live(log_in_user(conn, user), "/moderation")

    assert message =~ "do not moderate"
  end

  test "shows reports about the moderator's boards and hides every other report", %{conn: conn} do
    mine = board("mine")
    theirs = board("theirs")
    author = setup_user("user")
    reporter = setup_user("user")
    moderator = moderator_of(mine)

    ours = report_article(article_in(mine, author, "Ours"), reporter)
    other_board = report_article(article_in(theirs, author, "Theirs"), reporter)

    {:ok, account_report} =
      Moderation.create_report(%{
        category: "harassment",
        reason: "Rude",
        reporter_id: reporter.id,
        reported_user_id: author.id
      })

    {:ok, lv, _html} = live(log_in_user(conn, moderator), "/moderation")

    assert has_element?(lv, "#moderation-report-#{ours.id}")
    refute has_element?(lv, "#moderation-report-#{other_board.id}")
    refute has_element?(lv, "#moderation-report-#{account_report.id}")
  end

  test "shows reports about comments on articles in the moderator's boards", %{conn: conn} do
    mine = board("comments")
    author = setup_user("user")
    reporter = setup_user("user")
    moderator = moderator_of(mine)
    article = article_in(mine, author)

    {:ok, comment} =
      Content.create_comment(%{
        "body" => "Abusive comment",
        "article_id" => article.id,
        "user_id" => author.id
      })

    {:ok, report} =
      Moderation.create_report(%{
        category: "harassment",
        reason: "Abusive",
        reporter_id: reporter.id,
        comment_id: comment.id
      })

    {:ok, lv, _html} = live(log_in_user(conn, moderator), "/moderation")

    assert has_element?(lv, "#moderation-report-#{report.id}", "Abusive comment")
  end

  test "a moderator resolves and dismisses reports about their board", %{conn: conn} do
    mine = board("resolving")
    author = setup_user("user")
    reporter = setup_user("user")
    moderator = moderator_of(mine)
    first = report_article(article_in(mine, author, "One"), reporter)
    second = report_article(article_in(mine, author, "Two"), reporter)

    {:ok, lv, _html} = live(log_in_user(conn, moderator), "/moderation")

    lv
    |> form("#moderation-resolve-form-#{first.id}", %{"note" => "Removed the link"})
    |> render_submit()

    lv |> element("#moderation-dismiss-#{second.id}") |> render_click()

    first = Repo.reload!(first)
    second = Repo.reload!(second)
    assert first.status == "resolved"
    assert first.resolution_note == "Removed the link"
    assert first.resolved_by_id == moderator.id
    assert second.status == "dismissed"
  end

  test "a moderator cannot act on a report about another board", %{conn: conn} do
    mine = board("mine-only")
    theirs = board("not-mine")
    author = setup_user("user")
    reporter = setup_user("user")
    moderator = moderator_of(mine)
    _visible = report_article(article_in(mine, author), reporter)
    hidden = report_article(article_in(theirs, author), reporter)

    {:ok, lv, _html} = live(log_in_user(conn, moderator), "/moderation")

    # The report is not on the page; the id still comes from the client.
    assert render_click(lv, "dismiss", %{"id" => to_string(hidden.id)}) =~ "Report not found"

    assert render_click(lv, "resolve", %{"report_id" => to_string(hidden.id), "note" => ""}) =~
             "Report not found"

    assert Repo.reload!(hidden).status == "open"
  end

  test "a moderator deletes reported content in their board, but not elsewhere", %{conn: conn} do
    mine = board("deleting")
    theirs = board("other-deleting")
    author = setup_user("user")
    reporter = setup_user("user")
    moderator = moderator_of(mine)
    ours = article_in(mine, author, "Remove me")
    theirs_article = article_in(theirs, author, "Leave me")
    report = report_article(ours, reporter)

    {:ok, lv, _html} = live(log_in_user(conn, moderator), "/moderation")

    lv |> element("#moderation-delete-article-#{report.id}") |> render_click()
    assert Repo.reload!(ours).deleted_at

    assert render_click(lv, "delete_content", %{
             "type" => "article",
             "id" => to_string(theirs_article.id)
           }) =~ "Article not found"

    refute Repo.reload!(theirs_article).deleted_at
  end

  test "an admin sees every board's reports here too", %{conn: conn} do
    admin = setup_user("admin")
    author = setup_user("user")
    reporter = setup_user("user")
    report = report_article(article_in(board("admin-view"), author), reporter)

    {:ok, lv, _html} = live(log_in_user(conn, admin), "/moderation")

    assert has_element?(lv, "#moderation-report-#{report.id}")
  end
end
