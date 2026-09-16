defmodule BaudrateWeb.ReportTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Moderation
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})

    reporter = setup_user("user")
    author = setup_user("user")

    board =
      %Board{}
      |> Board.changeset(%{name: "Report Board", slug: "report-board"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Reportable Article",
          body: "Some content",
          slug: "reportable-article",
          user_id: author.id
        },
        [board.id]
      )

    {:ok, comment} =
      Content.create_comment(%{
        "body" => "Reportable comment",
        "article_id" => article.id,
        "user_id" => author.id
      })

    conn = log_in_user(conn, reporter)

    {:ok,
     conn: conn,
     reporter: reporter,
     author: author,
     board: board,
     article: article,
     comment: comment}
  end

  describe "citing a rule (P1-D9)" do
    test "the picker appears only once rules are published", %{conn: conn, article: article} do
      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

      lv
      |> element("button[phx-click=open_report_modal][phx-value-type=article]")
      |> render_click()

      refute has_element?(lv, "#report-rule-field")
    end

    test "a reporter can name the rule they say was broken", %{
      conn: conn,
      article: article,
      reporter: reporter
    } do
      {:ok, rule} = Baudrate.Setup.create_rule(%{"title" => "No spam"})

      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

      html =
        lv
        |> element("button[phx-click=open_report_modal][phx-value-type=article]")
        |> render_click()

      assert html =~ "Which rule?"
      assert html =~ "1. No spam"

      lv
      |> form("#report-modal form", %{
        reason: "Breaks rule one.",
        category: "rule_violation",
        rule_id: to_string(rule.id)
      })
      |> render_submit()

      assert %{rule_id: rule_id, category: "rule_violation"} =
               Repo.get_by(Moderation.Report, reporter_id: reporter.id)

      assert rule_id == rule.id
    end

    test "naming no rule is allowed, so reporting stays easy", %{
      conn: conn,
      article: article,
      reporter: reporter
    } do
      {:ok, _} = Baudrate.Setup.create_rule(%{"title" => "No spam"})

      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

      lv
      |> element("button[phx-click=open_report_modal][phx-value-type=article]")
      |> render_click()

      lv
      |> form("#report-modal form", %{
        reason: "Not sure which rule, but this is wrong.",
        category: "rule_violation",
        rule_id: ""
      })
      |> render_submit()

      assert %{rule_id: nil} = Repo.get_by(Moderation.Report, reporter_id: reporter.id)
    end

    test "a retired rule is no longer offered", %{conn: conn, article: article} do
      {:ok, rule} = Baudrate.Setup.create_rule(%{"title" => "Retired rule"})
      {:ok, _} = Baudrate.Setup.retire_rule(rule)

      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

      html =
        lv
        |> element("button[phx-click=open_report_modal][phx-value-type=article]")
        |> render_click()

      refute html =~ "Retired rule"
    end
  end

  describe "report article" do
    test "authenticated user can report an article", %{conn: conn, article: article} do
      {:ok, lv, html} = live(conn, "/articles/#{article.slug}")

      # Report button is visible
      assert html =~ "hero-flag"

      # Open the report modal
      html =
        lv
        |> element("button[phx-click=open_report_modal][phx-value-type=article]")
        |> render_click()

      assert html =~ "Report Article"
      assert html =~ "Reportable Article"

      # Submit the report
      lv
      |> form("#report-modal form", %{reason: "This article is spam", category: "spam"})
      |> render_submit()

      flash = assert_redirected_or_flash(lv)
      assert flash =~ "Report submitted" || render(lv) =~ "Report submitted"
    end

    test "duplicate report shows error", %{
      conn: conn,
      reporter: reporter,
      article: article
    } do
      # Create an existing open report
      Moderation.create_report(%{
        category: "spam",
        reason: "Already reported",
        reporter_id: reporter.id,
        article_id: article.id
      })

      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

      lv
      |> element("button[phx-click=open_report_modal][phx-value-type=article]")
      |> render_click()

      html =
        lv
        |> form("#report-modal form", %{reason: "Duplicate report", category: "spam"})
        |> render_submit()

      assert html =~ "already reported"
    end

    test "self-report button not shown for own article", %{
      author: author,
      article: article
    } do
      conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_user(author)

      {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")

      # The report button should not be rendered for the article author
      refute html =~
               ~s(phx-click="open_report_modal" phx-value-type="article" phx-value-id="#{article.id}")
    end
  end

  describe "report comment" do
    test "authenticated user can report a comment", %{
      conn: conn,
      article: article,
      comment: comment
    } do
      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

      # Open report modal for the comment
      lv
      |> element(
        "button[phx-click=open_report_modal][phx-value-type=comment][phx-value-id=\"#{comment.id}\"]"
      )
      |> render_click()

      html =
        lv
        |> form("#report-modal form", %{reason: "This comment is abusive", category: "spam"})
        |> render_submit()

      assert html =~ "Report submitted"
    end
  end

  describe "report user from profile" do
    test "authenticated user can report another user from profile", %{
      conn: conn,
      author: author
    } do
      {:ok, lv, html} = live(conn, "/users/#{author.username}")

      # Report button is visible
      assert html =~ "hero-flag"

      # Open report modal
      lv
      |> element("button[phx-click=open_report_modal][phx-value-type=user]")
      |> render_click()

      html =
        lv
        |> form("#report-modal form", %{reason: "Harassment", category: "spam"})
        |> render_submit()

      assert html =~ "Report submitted"
    end

    test "duplicate user report shows error", %{
      conn: conn,
      reporter: reporter,
      author: author
    } do
      Moderation.create_report(%{
        category: "spam",
        reason: "Already reported",
        reporter_id: reporter.id,
        reported_user_id: author.id
      })

      {:ok, lv, _html} = live(conn, "/users/#{author.username}")

      lv
      |> element("button[phx-click=open_report_modal][phx-value-type=user]")
      |> render_click()

      html =
        lv
        |> form("#report-modal form", %{reason: "Duplicate", category: "spam"})
        |> render_submit()

      assert html =~ "already reported"
    end
  end

  describe "guest user" do
    test "guest sees no report buttons on article page", %{article: article} do
      conn = Phoenix.ConnTest.build_conn()
      {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")

      refute html =~ "open_report_modal"
    end

    test "guest sees no report button on profile page", %{author: author} do
      conn = Phoenix.ConnTest.build_conn()
      {:ok, _lv, html} = live(conn, "/users/#{author.username}")

      refute html =~ "open_report_modal"
    end
  end

  # Helper to handle flash assertion in both redirect and in-page scenarios
  defp assert_redirected_or_flash(lv) do
    render(lv)
  rescue
    _ -> ""
  end
end
