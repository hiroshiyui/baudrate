defmodule BaudrateWeb.Admin.FiltersLiveTest do
  @moduledoc """
  `/admin/filters` (ADR 0065). The matching and the actions are gated in
  `Baudrate.Moderation.ContentFilterTest`; this checks the page adds,
  changes and deletes filters, shows the context's refusals, and counts
  matches, and that it is an admin's page only.
  """
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Moderation.{ContentFilter, ContentFilters}
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    admin = setup_user("admin")
    {:ok, conn: log_in_admin(conn, admin), admin: admin}
  end

  test "adds a filter through the form and lists it", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/admin/filters")

    html =
      lv
      |> form("#filters-form",
        filter: %{pattern: "Casino", kind: "word", action: "block", applies_to: "both"}
      )
      |> render_submit()

    assert html =~ "Filter “casino” added."
    assert html =~ ~s(id="filters-table")
    assert [%ContentFilter{pattern: "casino", action: "block"}] = ContentFilters.list_filters()
  end

  # The browser crawl found this: `validate` handed the params to the
  # changeset as if they were the filter, and the view crashed on the first
  # keystroke.
  test "typing validates and keeps what was typed", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/admin/filters")

    html =
      lv
      |> form("#filters-form", filter: %{pattern: "half typed", kind: "domain"})
      |> render_change()

    assert html =~ ~s(value="half typed")
    assert html =~ "is not a domain name"
  end

  test "shows the refusal and keeps what was typed", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/admin/filters")

    html =
      lv
      |> form("#filters-form", filter: %{pattern: "not a domain", kind: "domain", action: "flag"})
      |> render_submit()

    assert html =~ "is not a domain name"
    assert html =~ ~s(value="not a domain")
    assert ContentFilters.list_filters() == []
  end

  test "switches a filter off, changes its action, and deletes it", %{conn: conn, admin: admin} do
    {:ok, filter} =
      ContentFilters.create_filter(
        %{"pattern" => "poker", "kind" => "word", "action" => "flag"},
        admin
      )

    {:ok, lv, _} = live(conn, "/admin/filters")

    lv |> element("#content-filter-toggle-#{filter.id}") |> render_click()
    refute Repo.get(ContentFilter, filter.id).enabled

    lv
    |> form("#content-filter-action-form-#{filter.id}", %{"filter_action" => "block"})
    |> render_change()

    assert Repo.get(ContentFilter, filter.id).action == "block"

    lv |> element("#content-filter-delete-#{filter.id}") |> render_click()
    refute Repo.get(ContentFilter, filter.id)
  end

  test "counts how often each filter matched", %{conn: conn, admin: admin} do
    {:ok, filter} =
      ContentFilters.create_filter(
        %{"pattern" => "poker", "kind" => "word", "action" => "flag"},
        admin
      )

    verdict = ContentFilters.screen(%{body: "poker night"}, mode: :post, user_id: admin.id)
    ContentFilters.record(verdict)
    ContentFilters.record(verdict)

    {:ok, lv, _} = live(conn, "/admin/filters")

    assert lv |> element("#content-filter-#{filter.id} .content-filter-matches") |> render() =~
             "2"
  end

  test "a moderator is not let in", %{conn: conn} do
    moderator = setup_user("moderator")

    assert {:error, {:redirect, _}} = live(log_in_admin(conn, moderator), "/admin/filters")
  end
end
