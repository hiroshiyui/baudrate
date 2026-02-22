defmodule BaudrateWeb.Admin.FederationLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.{Content, Repo}
  alias Baudrate.Federation.DeliveryJob
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  defp create_failed_delivery_job do
    %DeliveryJob{}
    |> DeliveryJob.create_changeset(%{
      activity_json: ~s({"type":"Create"}),
      inbox_url: "https://remote.example/inbox",
      actor_uri: "https://localhost/ap/site"
    })
    |> Ecto.Changeset.change(%{status: "failed", attempts: 2, last_error: "connection refused"})
    |> Repo.insert!()
  end

  defp create_board_for_federation(name) do
    {:ok, board} =
      Content.create_board(%{
        name: name,
        slug: "fed-board-#{System.unique_integer([:positive])}",
        ap_enabled: false,
        min_role_to_view: "guest"
      })

    board
  end

  test "admin can access federation page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/federation")
    assert html =~ "Federation Dashboard"
  end

  test "non-admin is redirected", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/federation")
  end

  test "retry a failed delivery job", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    job = create_failed_delivery_job()

    {:ok, lv, _html} = live(conn, "/admin/federation")

    html =
      lv
      |> element("button[phx-click=\"retry_job\"][phx-value-id=\"#{job.id}\"]")
      |> render_click()

    assert html =~ "Job queued for retry."

    updated_job = Repo.get!(DeliveryJob, job.id)
    assert updated_job.status == "pending"
  end

  test "abandon a delivery job", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    job = create_failed_delivery_job()

    {:ok, lv, _html} = live(conn, "/admin/federation")

    html =
      lv
      |> element("button[phx-click=\"abandon_job\"][phx-value-id=\"#{job.id}\"]")
      |> render_click()

    assert html =~ "Job abandoned."

    updated_job = Repo.get!(DeliveryJob, job.id)
    assert updated_job.status == "abandoned"
  end

  test "block a domain", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    # Create a remote actor so the domain shows up in known instances
    uid = System.unique_integer([:positive])

    Repo.insert!(%Baudrate.Federation.RemoteActor{
      ap_id: "https://evil.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "evil.example",
      public_key_pem: elem(Baudrate.Federation.KeyStore.generate_keypair(), 0),
      inbox: "https://evil.example/users/actor-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    {:ok, lv, _html} = live(conn, "/admin/federation")

    html =
      lv
      |> element("button[phx-click=\"block_domain\"][phx-value-domain=\"evil.example\"]")
      |> render_click()

    assert html =~ "evil.example"
    assert html =~ "has been blocked"

    blocklist = Baudrate.Setup.get_setting("ap_domain_blocklist")
    assert blocklist =~ "evil.example"
  end

  test "toggle board federation", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    board = create_board_for_federation("Toggle Board")

    {:ok, lv, _html} = live(conn, "/admin/federation")

    html =
      lv
      |> element("button[phx-click=\"toggle_board_federation\"][phx-value-id=\"#{board.id}\"]")
      |> render_click()

    assert html =~ "Toggle Board"
    assert html =~ "enabled" or html =~ "disabled"

    updated_board = Repo.get!(Content.Board, board.id)
    assert updated_board.ap_enabled == true
  end

  test "rotate site keys", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/federation")

    html =
      lv
      |> element("button[phx-click=\"rotate_keys\"][phx-value-type=\"site\"]")
      |> render_click()

    assert html =~ "Keys rotated successfully."
  end

  test "displays delivery queue stats", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    # Create some delivery jobs with different statuses
    create_failed_delivery_job()

    %DeliveryJob{}
    |> DeliveryJob.create_changeset(%{
      activity_json: ~s({"type":"Create"}),
      inbox_url: "https://other.example/inbox",
      actor_uri: "https://localhost/ap/site"
    })
    |> Repo.insert!()

    {:ok, _lv, html} = live(conn, "/admin/federation")

    assert html =~ "Delivery Queue"
    assert html =~ "Pending"
    assert html =~ "Failed"
  end
end
