defmodule BaudrateWeb.Admin.ModerationLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  import Ecto.Query
  alias Baudrate.{Content, Moderation, Repo}
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  defp create_report_with_article(reporter) do
    {:ok, board} =
      Content.create_board(%{
        name: "Report Board",
        slug: "report-board-#{System.unique_integer([:positive])}"
      })

    slug = "reported-art-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Reported Article", body: "Bad content", slug: slug, user_id: reporter.id},
        [board.id]
      )

    {:ok, report} =
      Moderation.create_report(%{
        category: "spam",
        reason: "Offensive content",
        reporter_id: reporter.id,
        article_id: article.id
      })

    {report, article}
  end

  defp create_report_with_comment(reporter) do
    {:ok, board} =
      Content.create_board(%{
        name: "Comment Board",
        slug: "comment-board-#{System.unique_integer([:positive])}"
      })

    slug = "comment-art-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Article With Comment", body: "Body", slug: slug, user_id: reporter.id},
        [board.id]
      )

    {:ok, comment} =
      Content.create_comment(%{
        "body" => "Bad comment here",
        "article_id" => article.id,
        "user_id" => reporter.id
      })

    {:ok, report} =
      Moderation.create_report(%{
        category: "spam",
        reason: "Spam comment",
        reporter_id: reporter.id,
        comment_id: comment.id
      })

    {report, comment}
  end

  test "admin can access moderation page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/moderation")
    assert html =~ "Moderation Queue"
  end

  test "moderator can access moderation page", %{conn: conn} do
    moderator = setup_user("moderator")
    conn = log_in_user(conn, moderator)

    {:ok, _lv, html} = live(conn, "/admin/moderation")
    assert html =~ "Moderation Queue"
  end

  test "regular user is redirected", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/moderation")
  end

  test "shows open reports by default", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {_report, _article} = create_report_with_article(admin)

    {:ok, _lv, html} = live(conn, "/admin/moderation")
    assert html =~ "Offensive content"
  end

  test "filter to resolved tab shows empty state", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/moderation")

    html =
      lv
      |> element("button[phx-click=\"filter\"][phx-value-status=\"resolved\"]")
      |> render_click()

    assert html =~ "No reports with status"
  end

  test "resolve a report", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {report, _article} = create_report_with_article(admin)

    {:ok, lv, _html} = live(conn, "/admin/moderation")

    html =
      lv
      |> form("form[phx-submit=\"resolve\"]", %{report_id: report.id, note: "Handled it"})
      |> render_submit()

    assert html =~ "Report resolved."
  end

  test "dismiss a report", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {report, _article} = create_report_with_article(admin)

    {:ok, lv, _html} = live(conn, "/admin/moderation")

    html =
      lv
      |> element("button[phx-click=\"dismiss\"][phx-value-id=\"#{report.id}\"]")
      |> render_click()

    assert html =~ "Report dismissed."
  end

  test "delete reported article", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {_report, article} = create_report_with_article(admin)

    {:ok, lv, _html} = live(conn, "/admin/moderation")

    html =
      lv
      |> element(
        "button[phx-click=\"delete_content\"][phx-value-type=\"article\"][phx-value-id=\"#{article.id}\"]"
      )
      |> render_click()

    assert html =~ "Article deleted."
  end

  test "delete reported comment", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {_report, comment} = create_report_with_comment(admin)

    {:ok, lv, _html} = live(conn, "/admin/moderation")

    html =
      lv
      |> element(
        "button[phx-click=\"delete_content\"][phx-value-type=\"comment\"][phx-value-id=\"#{comment.id}\"]"
      )
      |> render_click()

    assert html =~ "Comment deleted."
  end

  # --- Bulk action tests ---

  describe "bulk select reports" do
    test "toggle_select_report adds and removes from selection", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)
      {report, _} = create_report_with_article(admin)

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      # Select
      html =
        lv
        |> element("input[phx-click=\"toggle_select_report\"][phx-value-id=\"#{report.id}\"]")
        |> render_click()

      assert html =~ "1 report selected"

      # Deselect
      html =
        lv
        |> element("input[phx-click=\"toggle_select_report\"][phx-value-id=\"#{report.id}\"]")
        |> render_click()

      refute html =~ "report selected"
    end

    test "toggle_select_all_reports selects and deselects all", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)
      {_, _} = create_report_with_article(admin)
      {_, _} = create_report_with_article(admin)

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      # Select all
      html = lv |> element("input[phx-click=\"toggle_select_all_reports\"]") |> render_click()
      assert html =~ "2 reports selected"

      # Deselect all
      html = lv |> element("input[phx-click=\"toggle_select_all_reports\"]") |> render_click()
      refute html =~ "report selected"
    end

    test "selection clears on filter change", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)
      {report, _} = create_report_with_article(admin)

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      # Select
      lv
      |> element("input[phx-click=\"toggle_select_report\"][phx-value-id=\"#{report.id}\"]")
      |> render_click()

      # Change filter
      html =
        lv
        |> element("button[phx-click=\"filter\"][phx-value-status=\"resolved\"]")
        |> render_click()

      refute html =~ "report selected"
    end

    test "checkboxes only shown for open reports", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)
      {report, _} = create_report_with_article(admin)
      Moderation.resolve_report(report, admin.id, "done")

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      html =
        lv
        |> element("button[phx-click=\"filter\"][phx-value-status=\"resolved\"]")
        |> render_click()

      refute html =~ "toggle_select_report"
      refute html =~ "toggle_select_all_reports"
    end
  end

  describe "bulk resolve" do
    test "resolves all selected reports with shared note", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)
      {report1, _} = create_report_with_article(admin)
      {report2, _} = create_report_with_article(admin)

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      # Select both
      lv
      |> element("input[phx-click=\"toggle_select_report\"][phx-value-id=\"#{report1.id}\"]")
      |> render_click()

      lv
      |> element("input[phx-click=\"toggle_select_report\"][phx-value-id=\"#{report2.id}\"]")
      |> render_click()

      # Open modal
      lv |> element("button[phx-click=\"show_bulk_resolve_modal\"]") |> render_click()

      # Set note
      lv
      |> form("form[phx-change=\"update_bulk_resolve_note\"]", note: "All handled")
      |> render_change()

      # Confirm
      html = lv |> element("button[phx-click=\"confirm_bulk_resolve\"]") |> render_click()
      assert html =~ "2 reports resolved"

      # Verify logs with bulk flag
      logs =
        Repo.all(
          from(l in Moderation.Log,
            where: l.action == "resolve_report" and l.actor_id == ^admin.id
          )
        )

      assert length(logs) == 2
      assert Enum.all?(logs, fn log -> log.details["bulk"] == true end)
      assert Enum.all?(logs, fn log -> log.details["note"] == "All handled" end)
    end

    test "cancel bulk resolve modal closes it", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)
      {report, _} = create_report_with_article(admin)

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      lv
      |> element("input[phx-click=\"toggle_select_report\"][phx-value-id=\"#{report.id}\"]")
      |> render_click()

      lv |> element("button[phx-click=\"show_bulk_resolve_modal\"]") |> render_click()

      html = lv |> element("button[phx-click=\"cancel_bulk_resolve\"]") |> render_click()
      refute html =~ "bulk-resolve-modal-title"
    end
  end

  describe "bulk dismiss" do
    test "dismisses all selected reports", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)
      {report1, _} = create_report_with_article(admin)
      {report2, _} = create_report_with_article(admin)

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      # Select both
      lv
      |> element("input[phx-click=\"toggle_select_report\"][phx-value-id=\"#{report1.id}\"]")
      |> render_click()

      lv
      |> element("input[phx-click=\"toggle_select_report\"][phx-value-id=\"#{report2.id}\"]")
      |> render_click()

      # Bulk dismiss
      html = lv |> element("button[phx-click=\"bulk_dismiss\"]") |> render_click()
      assert html =~ "2 reports dismissed"

      # Verify logs with bulk flag
      logs =
        Repo.all(
          from(l in Moderation.Log,
            where: l.action == "dismiss_report" and l.actor_id == ^admin.id
          )
        )

      assert length(logs) == 2
      assert Enum.all?(logs, fn log -> log.details["bulk"] == true end)
    end
  end

  describe "accessibility" do
    test "status filters are toggle buttons with aria-pressed, not tabs", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      assert has_element?(lv, "#admin-moderation-status-tabs[role=\"toolbar\"]")
      refute has_element?(lv, "[role=\"tab\"]")
      refute has_element?(lv, "[role=\"tablist\"]")
      assert has_element?(lv, "#admin-moderation-tab-open[aria-pressed=\"true\"]")

      lv |> element("#admin-moderation-tab-resolved") |> render_click()

      assert has_element?(lv, "#admin-moderation-tab-resolved[aria-pressed=\"true\"]")
      assert has_element?(lv, "#admin-moderation-tab-open[aria-pressed=\"false\"]")
    end

    test "row actions name their report and focus returns to heading on dismiss", %{
      conn: conn
    } do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {report, _article} = create_report_with_article(admin)

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      assert has_element?(
               lv,
               "#admin-moderation-dismiss-#{report.id}[aria-label=\"Dismiss report ##{report.id}\"]"
             )

      assert has_element?(
               lv,
               "#admin-moderation-resolve-submit-#{report.id}[aria-label=\"Resolve report ##{report.id}\"]"
             )

      lv |> element("#admin-moderation-dismiss-#{report.id}") |> render_click()
      assert_push_event(lv, "focus", %{id: "admin-moderation-heading"})
    end
  end

  describe "member reports of timeline items and messages" do
    test "shows the reported timeline item and only the copied message text", %{conn: conn} do
      admin = setup_user("admin")
      member = setup_user("user")
      sender = setup_user("user")
      uid = System.unique_integer([:positive])

      actor =
        %Baudrate.Federation.RemoteActor{}
        |> Baudrate.Federation.RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/q-#{uid}",
          username: "q_#{uid}",
          domain: "remote.example",
          public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
          inbox: "https://remote.example/users/q-#{uid}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert!()

      {:ok, follow} = Baudrate.Federation.create_user_follow(member, actor)
      {:ok, _} = Baudrate.Federation.accept_user_follow(follow.ap_id)

      {:ok, item} =
        Baudrate.Federation.create_timeline_item(%{
          remote_actor_id: actor.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/#{uid}",
          body: "Cheap pills",
          body_html: "<p>Cheap pills</p>",
          source_url: "https://remote.example/notes/#{uid}",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, feed_report} =
        Moderation.report_timeline_item(member, item.id, %{reason: "Spam post", category: "spam"})

      {:ok, conversation} = Baudrate.Messaging.find_or_create_conversation(sender, member)
      {:ok, _} = Baudrate.Messaging.create_message(conversation, sender, %{"body" => "Earlier"})
      {:ok, dm} = Baudrate.Messaging.create_message(conversation, sender, %{"body" => "Threat"})

      {:ok, dm_report} =
        Moderation.report_message(member, dm.id, %{reason: "Harassing me", category: "spam"})

      conn = log_in_admin(conn, admin)
      {:ok, lv, html} = live(conn, "/admin/moderation")

      assert has_element?(
               lv,
               "#admin-moderation-report-feed-item-#{feed_report.id}",
               "Cheap pills"
             )

      assert has_element?(lv, "#admin-moderation-report-message-#{dm_report.id}", "Threat")
      refute html =~ "Earlier"
    end
  end

  describe "outcome notices (P1-D4)" do
    test "resolving tells the reporter; deleting tells the author with the reason", %{conn: conn} do
      admin = setup_user("admin")
      reporter = setup_user("user")
      {report, article} = create_report_with_article(reporter)

      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/moderation")

      lv |> element("#admin-moderation-delete-article-#{report.id}") |> render_click()

      lv
      |> form("#admin-moderation-resolve-form-#{report.id}", %{"note" => "Removed"})
      |> render_submit()

      assert [reviewed] = notifications_of(reporter, "report_reviewed")
      assert reviewed.data["report_id"] == report.id

      # The reporter here is also the author of the test article.
      assert [removed] = notifications_of(article.user_id, "content_removed")
      assert removed.data["reason_category"] == "spam"
      assert removed.actor_user_id == admin.id
    end

    test "a comment deleted from the queue records who deleted it", %{conn: conn} do
      admin = setup_user("admin")
      reporter = setup_user("user")
      {report, comment} = create_report_with_comment(reporter)

      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/moderation")
      lv |> element("#admin-moderation-delete-comment-#{report.id}") |> render_click()

      comment = Repo.reload!(comment)
      assert comment.deleted_at
      assert comment.deleted_by_id == admin.id
    end
  end

  describe "reports a content filter opened (ADR 0065)" do
    test "say which filter, not who reported them", %{conn: conn} do
      admin = setup_user("admin")
      author = setup_user("user")

      {:ok, _} =
        Baudrate.Moderation.ContentFilters.create_filter(
          %{"pattern" => "poker", "kind" => "word", "action" => "flag"},
          admin
        )

      {:ok, board} =
        Content.create_board(%{
          name: "Filtered",
          slug: "filtered-#{System.unique_integer([:positive])}"
        })

      {:ok, %{article: article}} =
        Content.submit_article(
          %{
            "title" => "Poker night",
            "body" => "Bring chips",
            "slug" => "poker-#{System.unique_integer([:positive])}",
            "user_id" => author.id
          },
          [board.id]
        )

      report = Repo.get_by!(Baudrate.Moderation.Report, article_id: article.id)

      {:ok, lv, _html} = live(log_in_admin(conn, admin), "/admin/moderation")

      assert has_element?(lv, "#admin-moderation-report-filter-#{report.id}", "poker")
      refute has_element?(lv, "#admin-moderation-report-reporter-#{report.id}")
    end

    test "a flagged timeline reply keeps a copy of its text", %{conn: conn} do
      admin = setup_user("admin")
      author = setup_user("user")

      {:ok, filter} =
        Baudrate.Moderation.ContentFilters.create_filter(
          %{"pattern" => "poker", "kind" => "word", "action" => "flag"},
          admin
        )

      verdict =
        Baudrate.Moderation.ContentFilters.screen(%{body: "poker?"},
          mode: :publish,
          target_type: "timeline_reply",
          user_id: author.id
        )

      :ok =
        Baudrate.Moderation.ContentFilters.flag(verdict, %{reported_user_id: author.id},
          evidence: "poker?"
        )

      report = Repo.get_by!(Baudrate.Moderation.Report, content_filter_id: filter.id)
      {:ok, lv, _html} = live(log_in_admin(conn, admin), "/admin/moderation")

      assert has_element?(lv, "#admin-moderation-report-user-evidence-#{report.id}", "poker?")
    end
  end

  describe "evidence retention (P1-D6)" do
    test "a removal keeps a copy of the content for staff, and the queue shows it", %{
      conn: conn
    } do
      admin = setup_user("admin")
      reporter = setup_user("user")
      {report, article} = create_report_with_article(reporter)

      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/moderation")
      lv |> element("#admin-moderation-delete-article-#{report.id}") |> render_click()

      report = Repo.reload!(report)
      assert report.evidence_body == article.body
      assert report.evidence_taken_at

      # The article itself now reads as deleted, but the report still explains
      # itself.
      assert has_element?(
               lv,
               "#admin-moderation-report-article-evidence-#{report.id}",
               article.body
             )
    end

    test "evidence is cleared 90 days after the report was closed", %{conn: conn} do
      admin = setup_user("admin")
      reporter = setup_user("user")
      {report, _article} = create_report_with_article(reporter)

      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/moderation")
      lv |> element("#admin-moderation-delete-article-#{report.id}") |> render_click()

      lv
      |> form("#admin-moderation-resolve-form-#{report.id}", %{"note" => ""})
      |> render_submit()

      assert Repo.reload!(report).evidence_body

      # Still inside the window.
      assert Moderation.purge_closed_report_evidence() == 0
      assert Repo.reload!(report).evidence_body

      long_ago =
        DateTime.utc_now() |> DateTime.add(-91 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(r in Baudrate.Moderation.Report, where: r.id == ^report.id),
        set: [resolved_at: long_ago]
      )

      assert Moderation.purge_closed_report_evidence() == 1
      report = Repo.reload!(report)
      refute report.evidence_body
      # The copy is gone; the report itself stays as the record of what happened.
      assert report.status == "resolved"
      assert report.evidence_taken_at
    end

    test "an open report's evidence is never purged, however old", %{conn: conn} do
      admin = setup_user("admin")
      reporter = setup_user("user")
      {report, _article} = create_report_with_article(reporter)

      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/moderation")
      lv |> element("#admin-moderation-delete-article-#{report.id}") |> render_click()

      long_ago =
        DateTime.utc_now() |> DateTime.add(-400 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(r in Baudrate.Moderation.Report, where: r.id == ^report.id),
        set: [inserted_at: long_ago]
      )

      assert Moderation.purge_closed_report_evidence() == 0
      assert Repo.reload!(report).evidence_body
    end
  end

  defp notifications_of(%{id: user_id}, type), do: notifications_of(user_id, type)

  defp notifications_of(user_id, type) do
    Repo.all(
      from(n in Baudrate.Notification.Notification,
        where: n.user_id == ^user_id and n.type == ^type
      )
    )
  end

  describe "queue basics (1B)" do
    test "shows the category, links to the reported article and the reporter's text", %{
      conn: conn
    } do
      admin = setup_user("admin")
      member = setup_user("user")
      {report, article} = create_report_with_article(member)

      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/moderation")

      assert has_element?(lv, "#admin-moderation-report-category-#{report.id}", "Spam")

      assert lv
             |> element("#admin-moderation-report-article-link-#{report.id}")
             |> render() =~ "/articles/#{article.slug}"

      # The whole reported text, not a preview.
      assert has_element?(lv, ".moderation-report-article-body", article.body)
    end

    test "links a reported comment to its place on the article, and a reported user to their profile",
         %{conn: conn} do
      admin = setup_user("admin")
      member = setup_user("user")
      {comment_report, comment} = create_report_with_comment(member)

      {:ok, user_report} =
        Moderation.create_report(%{
          category: "harassment",
          reason: "Abusive",
          reporter_id: member.id,
          reported_user_id: member.id
        })

      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/moderation")

      link =
        lv |> element("#admin-moderation-report-comment-link-#{comment_report.id}") |> render()

      assert link =~ "#comment-#{comment.id}"

      assert lv
             |> element("#admin-moderation-report-user-link-#{user_report.id}")
             |> render() =~ "/users/#{member.username}"
    end

    test "says how many other open reports the same target has", %{conn: conn} do
      admin = setup_user("admin")
      first_reporter = setup_user("user")
      second_reporter = setup_user("user")
      {first, article} = create_report_with_article(first_reporter)

      {:ok, second} =
        Moderation.create_report(%{
          category: "spam",
          reason: "Same article",
          reporter_id: second_reporter.id,
          article_id: article.id
        })

      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/moderation")

      assert has_element?(
               lv,
               "#admin-moderation-report-others-#{first.id}",
               "1 other open report"
             )

      assert has_element?(lv, "#admin-moderation-report-others-#{second.id}")
    end

    test "pages through the queue and keeps the status filter", %{conn: conn} do
      admin = setup_user("admin")
      member = setup_user("user")

      reports =
        for n <- 1..21 do
          {:ok, report} =
            Moderation.create_report(%{
              category: "other",
              reason: "Report number #{n}",
              reporter_id: member.id,
              reported_user_id: setup_user("user").id
            })

          report
        end

      newest = List.last(reports)
      oldest = List.first(reports)

      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/moderation")

      assert has_element?(lv, "#admin-moderation-report-#{newest.id}")
      refute has_element?(lv, "#admin-moderation-report-#{oldest.id}")

      {:ok, lv, _html} = live(conn, "/admin/moderation?page=2")
      assert has_element?(lv, "#admin-moderation-report-#{oldest.id}")
      refute has_element?(lv, "#admin-moderation-report-#{newest.id}")

      # The pager keeps the status the queue is showing.
      {:ok, lv, _html} = live(conn, "/admin/moderation?status=resolved")
      refute has_element?(lv, "#admin-moderation-report-#{newest.id}")
      assert has_element?(lv, "#admin-moderation-tab-resolved")
    end
  end

  describe "a report about a remote account" do
    defp create_remote_actor_report(reporter) do
      n = System.unique_integer([:positive])

      actor =
        Repo.insert!(%Baudrate.Federation.RemoteActor{
          ap_id: "https://spam.example/users/loud#{n}",
          username: "loud#{n}",
          domain: "spam.example",
          public_key_pem: elem(Baudrate.Federation.KeyStore.generate_keypair(), 0),
          inbox: "https://spam.example/users/loud#{n}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, report} =
        Moderation.create_report(%{
          category: "harassment",
          reason: "Sustained abuse",
          reporter_id: reporter.id,
          remote_actor_id: actor.id
        })

      {report, actor}
    end

    test "offers an admin somewhere to act on it", %{conn: conn} do
      # Before this the queue showed the report and gave staff nothing to do
      # with it but block the account's whole domain by hand.
      admin = setup_user("admin")
      {report, _actor} = create_remote_actor_report(admin)
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      assert has_element?(lv, "#admin-moderation-report-instance-link-#{report.id}")

      assert lv
             |> element("#admin-moderation-report-instance-link-#{report.id}")
             |> render() =~ "/admin/federation/instances/spam.example"
    end

    test "does not offer it to a moderator, who cannot open that page", %{conn: conn} do
      moderator = setup_user("moderator")
      {report, _actor} = create_remote_actor_report(moderator)
      conn = log_in_user(conn, moderator)

      {:ok, lv, _html} = live(conn, "/admin/moderation")

      refute has_element?(lv, "#admin-moderation-report-instance-link-#{report.id}")
    end
  end
end
