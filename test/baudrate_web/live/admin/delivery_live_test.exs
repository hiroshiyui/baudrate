defmodule BaudrateWeb.Admin.DeliveryLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Baudrate.Federation.{DeliveryCircuit, DeliveryJob}
  alias Baudrate.Moderation.Log
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    admin = setup_user("admin")
    %{conn: log_in_admin(conn, admin), admin: admin}
  end

  defp job(domain, status \\ "pending") do
    uid = System.unique_integer([:positive])

    {:ok, job} =
      DeliveryJob.create_changeset(%{
        activity_json: ~s({"id":"https://local.example/a/#{uid}"}),
        inbox_url: "https://#{domain}/inbox",
        actor_uri: "https://local.example/ap/users/u#{uid}"
      })
      |> Repo.insert()

    job |> Ecto.Changeset.change(status: status) |> Repo.update!()
  end

  defp open_circuit(domain) do
    Repo.insert!(%DeliveryCircuit{
      domain: domain,
      failures: 5,
      trips: 1,
      open_until: DateTime.utc_now(:second) |> DateTime.add(600)
    })
  end

  defp logged(action), do: Repo.all(from(l in Log, where: l.action == ^action))

  test "lists waiting jobs and filters them by exact domain", %{conn: conn} do
    mine = job("peer.example", "failed")
    other = job("notpeer.example")

    {:ok, lv, _html} = live(conn, "/admin/federation/delivery")
    assert has_element?(lv, "#admin-delivery-job-#{mine.id}")
    assert has_element?(lv, "#admin-delivery-job-#{other.id}")

    lv |> form("#admin-delivery-filter-form", %{domain: "peer.example"}) |> render_change()
    assert_patch(lv, "/admin/federation/delivery?domain=peer.example")

    assert has_element?(lv, "#admin-delivery-job-#{mine.id}")
    refute has_element?(lv, "#admin-delivery-job-#{other.id}")
  end

  test "retries a failed job and abandons a pending one", %{conn: conn} do
    failed = job("peer.example", "failed")
    pending = job("peer.example")

    {:ok, lv, _html} = live(conn, "/admin/federation/delivery")
    refute has_element?(lv, "#admin-delivery-job-retry-#{pending.id}")

    # Each row's controls name the inbox they act on.
    assert has_element?(
             lv,
             ~s(#admin-delivery-job-abandon-#{pending.id}[aria-label="Abandon delivery to #{pending.inbox_url}"])
           )

    assert has_element?(
             lv,
             ~s(#admin-delivery-job-#{pending.id} th[scope="row"]),
             pending.inbox_url
           )

    assert lv |> element("#admin-delivery-job-retry-#{failed.id}") |> render_click() =~
             "Job queued for retry."

    assert Repo.get!(DeliveryJob, failed.id).status == "pending"
    assert_push_event(lv, "focus", %{id: "admin-delivery-jobs-heading"})

    assert lv |> element("#admin-delivery-job-abandon-#{pending.id}") |> render_click() =~
             "Job abandoned."

    assert Repo.get!(DeliveryJob, pending.id).status == "abandoned"
    refute has_element?(lv, "#admin-delivery-job-#{pending.id}")
  end

  test "a crafted retry of a delivered job sends nothing twice", %{conn: conn} do
    delivered = job("peer.example", "delivered")
    {:ok, lv, _html} = live(conn, "/admin/federation/delivery")

    render_click(lv, "retry_job", %{"id" => to_string(delivered.id)})
    assert Repo.get!(DeliveryJob, delivered.id).status == "delivered"
  end

  test "bulk actions act on the filtered domain only, and abandoning is logged", %{conn: conn} do
    a = job("peer.example", "failed")
    b = job("peer.example")
    lookalike = job("peer.example.org", "failed")

    {:ok, lv, _html} = live(conn, "/admin/federation/delivery")
    refute has_element?(lv, "#admin-delivery-domain-actions")

    {:ok, lv, _html} = live(conn, "/admin/federation/delivery?domain=peer.example")

    lv |> element("#admin-delivery-retry-domain") |> render_click()
    assert Repo.get!(DeliveryJob, a.id).status == "pending"
    assert Repo.get!(DeliveryJob, lookalike.id).status == "failed"
    assert logged("abandon_deliveries") == []

    lv |> element("#admin-delivery-abandon-domain") |> render_click()
    assert Repo.get!(DeliveryJob, a.id).status == "abandoned"
    assert Repo.get!(DeliveryJob, b.id).status == "abandoned"
    assert Repo.get!(DeliveryJob, lookalike.id).status == "failed"

    assert [%{details: %{"domain" => "peer.example", "count" => 2}}] =
             logged("abandon_deliveries")
  end

  test "a bulk event without a filtered domain does nothing", %{conn: conn} do
    j = job("peer.example")
    {:ok, lv, _html} = live(conn, "/admin/federation/delivery")

    render_click(lv, "abandon_domain", %{"domain" => "peer.example"})
    assert Repo.get!(DeliveryJob, j.id).status == "pending"
  end

  test "lists open circuits and closes one, in the log", %{conn: conn} do
    open_circuit("down.example")

    {:ok, lv, _html} = live(conn, "/admin/federation/delivery")
    assert has_element?(lv, ".admin-delivery-circuit-domain", "down.example")

    lv |> element(~s([id="admin-delivery-circuit-close-down.example"])) |> render_click()

    refute Repo.get(DeliveryCircuit, "down.example")
    refute has_element?(lv, ".admin-delivery-circuit-domain", "down.example")
    assert has_element?(lv, "#admin-delivery-circuits-empty")

    assert [%{details: %{"domain" => "down.example", "trips" => 1}}] =
             logged("close_delivery_circuit")

    render_click(lv, "close_circuit", %{"domain" => "down.example"})
    assert length(logged("close_delivery_circuit")) == 1
  end

  test "pages through the jobs", %{conn: conn} do
    for _ <- 1..51, do: job("peer.example")

    {:ok, lv, _html} = live(conn, "/admin/federation/delivery?domain=peer.example&page=2")
    assert length(Regex.scan(~r/class="admin-delivery-job"/, render(lv))) == 1
  end

  test "a moderator is turned away" do
    moderator = setup_user("moderator")
    conn = log_in_user(build_conn(), moderator)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/federation/delivery")
  end

  test "the federation page links here instead of listing jobs", %{conn: conn} do
    j = job("peer.example", "failed")
    {:ok, lv, _html} = live(conn, "/admin/federation")

    assert has_element?(
             lv,
             ~s(#admin-federation-delivery-link[href="/admin/federation/delivery"])
           )

    refute has_element?(lv, "#admin-federation-job-#{j.id}")
  end
end
