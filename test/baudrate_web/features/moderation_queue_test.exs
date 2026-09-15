defmodule BaudrateWeb.Features.ModerationQueueTest do
  use BaudrateWeb.FeatureCase, async: false

  import Ecto.Query

  alias Baudrate.{Moderation, Repo}
  alias Baudrate.Moderation.{Log, Report}

  @moduletag :feature

  feature "a member reports an article and a moderator resolves it with a note", %{
    session: session
  } do
    author = setup_user("user")
    reporter = setup_user("user")
    article = create_article(author, create_board(%{}), %{title: "Buy cheap watches"})

    session
    |> log_in_via_browser(reporter)
    |> visit("/articles/#{article.slug}")
    |> click(Query.css("#article-menu-trigger"))
    |> click(Query.css("#article-menu-report"))
    |> click(Query.css("#report-category option[value=spam]"))
    |> fill_in(Query.css("#report-reason"), with: "Spam with a shop link")
    |> click(Query.css("#report-modal .report-modal-submit"))
    |> assert_has(Query.text("Report submitted. Thank you."))
    |> refute_has(Query.css("#report-modal"))

    report = Repo.get_by!(Report, article_id: article.id, reporter_id: reporter.id)
    {moderator, secret} = enable_totp!(setup_user("moderator"))

    start_another_session()
    |> log_in_with_totp_via_browser(moderator, secret)
    |> visit_admin("/admin/moderation", {moderator, secret})
    |> assert_has(
      Query.css("#admin-moderation-report-#{report.id}", text: "Spam with a shop link")
    )
    |> fill_in(Query.css("#admin-moderation-resolve-note-#{report.id}"), with: "Link removed")
    |> click(Query.css("#admin-moderation-resolve-submit-#{report.id}"))
    |> assert_has(Query.text("Report resolved."))
    |> assert_has(Query.css("#admin-moderation-empty"))
    |> click(Query.css("#admin-moderation-tab-resolved"))
    |> assert_has(
      Query.css("#admin-moderation-report-handled-by-#{report.id}", text: "Link removed")
    )

    assert Repo.reload!(report).status == "resolved"
    assert logged?(moderator, "resolve_report")
  end

  feature "a moderator deletes reported content and dismisses a report", %{session: session} do
    {moderator, secret} = enable_totp!(setup_user("moderator"))
    reporter = setup_user("user")
    board = create_board(%{})
    spam = create_article(setup_user("user"), board, %{title: "Spam article"})
    fine = create_article(setup_user("user"), board, %{title: "Fine article"})
    spam_report = report!(reporter, spam, "Spam")
    fine_report = report!(reporter, fine, "I disagree with it")

    session =
      session
      |> log_in_with_totp_via_browser(moderator, secret)
      |> visit_admin("/admin/moderation", {moderator, secret})

    # Deleting asks for confirmation through window.confirm (data-confirm).
    session
    |> execute_script("window.confirm = () => true")
    |> click(Query.css("#admin-moderation-delete-article-#{spam_report.id}"))
    |> assert_has(Query.text("Article deleted."))
    |> refute_has(Query.css("#admin-moderation-delete-article-#{spam_report.id}"))
    |> click(Query.css("#admin-moderation-dismiss-#{fine_report.id}"))
    |> assert_has(Query.text("Report dismissed."))
    |> refute_has(Query.css("#admin-moderation-report-#{fine_report.id}"))
    |> click(Query.css("#admin-moderation-tab-dismissed"))
    |> assert_has(Query.css("#admin-moderation-report-#{fine_report.id}"))

    assert Repo.reload!(spam).deleted_at
    assert is_nil(Repo.reload!(fine).deleted_at)
    assert Repo.reload!(fine_report).status == "dismissed"
  end

  feature "a moderator resolves several reports at once with one note", %{session: session} do
    {moderator, secret} = enable_totp!(setup_user("moderator"))
    reporter = setup_user("user")
    board = create_board(%{})

    reports =
      for n <- 1..2 do
        report!(reporter, create_article(setup_user("user"), board, %{}), "Duplicate #{n}")
      end

    session
    |> log_in_with_totp_via_browser(moderator, secret)
    |> visit_admin("/admin/moderation", {moderator, secret})
    |> click(Query.css("#admin-moderation-select-all"))
    |> assert_has(Query.css("#admin-moderation-selected-count", text: "2 reports selected"))
    |> click(Query.css("#admin-moderation-bulk-resolve"))
    |> fill_in(Query.css("#bulk-resolve-note"), with: "Same duplicate thread")
    |> click(Query.css("#admin-moderation-bulk-confirm"))
    |> assert_has(Query.css("#admin-moderation-empty"))
    |> refute_has(Query.css("#bulk-resolve-modal"))

    for report <- reports do
      report = Repo.reload!(report)
      assert report.status == "resolved"
      assert report.resolution_note == "Same duplicate thread"
    end
  end

  defp report!(reporter, article, reason) do
    {:ok, report} =
      Moderation.create_report(%{
        reporter_id: reporter.id,
        article_id: article.id,
        category: "spam",
        reason: reason
      })

    report
  end

  defp logged?(user, action) do
    Repo.exists?(from(l in Log, where: l.actor_id == ^user.id and l.action == ^action))
  end
end
