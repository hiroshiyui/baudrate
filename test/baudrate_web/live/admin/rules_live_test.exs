defmodule BaudrateWeb.Admin.RulesLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Moderation
  alias Baudrate.Repo
  alias Baudrate.Setup

  setup do
    Repo.insert!(%Setup.Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setup.Setting{key: "site_name", value: "Test Site"})
    :ok
  end

  defp rule(title) do
    {:ok, created} = Setup.create_rule(%{"title" => title})
    created
  end

  defp actions do
    Moderation.list_moderation_logs().logs |> Enum.map(& &1.action)
  end

  test "adds a rule and logs it", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/rules")

    html =
      lv
      |> form("#admin-rules-new-form", rule: %{title: "Be civil", body: "No insults."})
      |> render_submit()

    assert html =~ "Rule added"
    assert [%{title: "Be civil", body: "No insults."}] = Setup.list_rules()
    assert "create_rule" in actions()
  end

  test "edits a rule in place", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)
    existing = rule("Be civil")

    {:ok, lv, _html} = live(conn, "/admin/rules")

    lv |> element("#admin-rule-edit-#{existing.id}") |> render_click()

    html =
      lv
      |> form("#admin-rule-edit-form-#{existing.id}", rule: %{title: "Be kind"})
      |> render_submit()

    assert html =~ "Rule saved"
    assert [%{title: "Be kind"}] = Setup.list_rules()
    assert "update_rule" in actions()
  end

  test "reorders rules", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)
    first = rule("First")
    _second = rule("Second")

    {:ok, lv, _html} = live(conn, "/admin/rules")

    lv |> element("#rule-move-#{first.id}-down") |> render_click()

    assert Enum.map(Setup.list_rules(), & &1.title) == ["Second", "First"]
    assert "reorder_rules" in actions()
  end

  test "retires a rule and offers to restore it", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)
    doomed = rule("Goes away")

    {:ok, lv, _html} = live(conn, "/admin/rules")

    html = lv |> element("#admin-rule-retire-#{doomed.id}") |> render_click()

    assert html =~ "Rule retired"
    assert Setup.list_rules() == []
    assert has_element?(lv, "#admin-rule-restore-#{doomed.id}")

    html = lv |> element("#admin-rule-restore-#{doomed.id}") |> render_click()

    assert html =~ "Rule restored"
    assert [%{title: "Goes away"}] = Setup.list_rules()
    assert "retire_rule" in actions()
    assert "restore_rule" in actions()
  end

  test "says when there are no rules at all", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/rules")

    assert has_element?(lv, "#admin-rules-empty")
  end

  test "is refused to a non-admin", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, _}} = live(conn, "/admin/rules")
  end
end
