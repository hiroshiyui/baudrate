defmodule BaudrateWeb.Admin.DashboardLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Health
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    :ok
  end

  test "an admin sees every section, and the health checks once connected", %{conn: conn} do
    admin = setup_user("admin")
    setup_user("user", %{status: "pending"})

    {:ok, lv, html} = live(log_in_admin(conn, admin), "/admin")

    for id <- ~w(moderation members federation health) do
      assert html =~ ~s(id="admin-dashboard-#{id}"), "missing section #{id}"
    end

    assert has_element?(lv, "#admin-dashboard-pending-registrations dd", "1")

    assert has_element?(
             lv,
             ~s(#admin-dashboard-pending-registrations a[href="/admin/pending-users"])
           )

    render_async(lv)

    for name <- Health.check_names() do
      assert has_element?(lv, "#admin-dashboard-health-#{name}"), "no row for #{name}"
    end

    refute has_element?(lv, "#admin-dashboard-health-loading")
  end

  # The report's reasons are English text for the operator's shell; the page
  # shows a translated status beside a translated name.
  test "a failing check shows its name and status, never the report's reason", %{conn: conn} do
    admin = setup_user("admin")
    {:ok, lv, _html} = live(log_in_admin(conn, admin), "/admin")
    html = render_async(lv)

    reasons =
      Health.report()
      |> Map.fetch!(:checks)
      |> Map.values()
      |> Enum.map(&Map.get(&1, :reason))
      |> Enum.reject(&is_nil/1)

    for reason <- reasons, do: refute(html =~ reason, "the page shows #{inspect(reason)}")
  end

  test "a moderator sees only what is waiting for review", %{conn: conn} do
    moderator = setup_user("moderator")
    {:ok, lv, html} = live(log_in_user(conn, moderator), "/admin")

    assert has_element?(lv, "#admin-dashboard-moderation")

    for id <- ~w(members federation health) do
      refute html =~ ~s(id="admin-dashboard-#{id}"), "a moderator sees #{id}"
    end
  end

  test "a member is turned away", %{conn: conn} do
    user = setup_user("user")
    assert {:error, {:redirect, %{to: "/"}}} = live(log_in_user(conn, user), "/admin")
  end

  test "both admin menus link to it", %{conn: conn} do
    moderator = setup_user("moderator")
    html = conn |> log_in_user(moderator) |> get("/admin") |> html_response(200)

    assert length(Regex.scan(~r{<a href="/admin"[^>]*class="nav-admin-link"}, html)) == 2
  end

  test "every health check has a heading" do
    for name <- Health.check_names() do
      title = BaudrateWeb.Helpers.health_check_title(to_string(name))
      refute title == to_string(name), "#{name} has no heading"
    end
  end

  test "the facts shown for a check tolerate a failure that carries no figures" do
    assert BaudrateWeb.Admin.DashboardLive.check_facts(:disk, %{status: :fail, reason: "x"}) == []

    assert [_] =
             BaudrateWeb.Admin.DashboardLive.check_facts(:disk, %{
               status: :ok,
               free_bytes: 5 * 1024 * 1024 * 1024,
               total_bytes: 20 * 1024 * 1024 * 1024
             })
  end
end
