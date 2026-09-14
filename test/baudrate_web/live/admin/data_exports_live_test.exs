defmodule BaudrateWeb.Admin.DataExportsLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.DataPortability.ExportRequest
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    :ok
  end

  defp insert_request(user, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ExportRequest{}
    |> ExportRequest.create_changeset(
      Map.merge(
        %{
          user_id: user.id,
          status: "completed",
          source: "self_service",
          requested_at: now,
          ready_at: now,
          expires_at: now,
          download_count: 2
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "admins see export requests with source, operator and status", %{conn: conn} do
    admin = setup_user("admin")
    user = setup_user("user")
    self_service = insert_request(user, %{})
    sysop = insert_request(user, %{source: "sysop", operator: "root", download_count: 1})

    {:ok, lv, _html} = live(log_in_admin(conn, admin), "/admin/data-exports")

    assert has_element?(lv, "#admin-data-export-#{self_service.id}", "Self-service")
    assert has_element?(lv, "#admin-data-export-#{sysop.id}", "SysOp")
    assert has_element?(lv, "#admin-data-export-#{sysop.id}", "root")

    assert has_element?(
             lv,
             "#admin-data-export-#{self_service.id} .admin-data-export-user",
             user.username
           )
  end

  test "moderators and users cannot open it", %{conn: conn} do
    for role <- ["moderator", "user"] do
      member = setup_user(role)

      assert {:error, {:redirect, _}} =
               live(log_in_user(conn, member), "/admin/data-exports")
    end
  end
end
