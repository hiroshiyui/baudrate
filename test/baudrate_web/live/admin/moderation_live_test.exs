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
        reason: "Spam comment",
        reporter_id: reporter.id,
        comment_id: comment.id
      })

    {report, comment}
  end

  test "admin can access moderation page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

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
    conn = log_in_user(conn, admin)

    {_report, _article} = create_report_with_article(admin)

    {:ok, _lv, html} = live(conn, "/admin/moderation")
    assert html =~ "Offensive content"
  end

  test "filter to resolved tab shows empty state", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/moderation")

    html =
      lv
      |> element("button[phx-click=\"filter\"][phx-value-status=\"resolved\"]")
      |> render_click()

    assert html =~ "No reports with status"
  end

  test "resolve a report", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

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
    conn = log_in_user(conn, admin)

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
    conn = log_in_user(conn, admin)

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
    conn = log_in_user(conn, admin)

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
      conn = log_in_user(conn, admin)
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
      conn = log_in_user(conn, admin)
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
      conn = log_in_user(conn, admin)
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
      conn = log_in_user(conn, admin)
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
      conn = log_in_user(conn, admin)
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
      conn = log_in_user(conn, admin)
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
      conn = log_in_user(conn, admin)
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
end
