defmodule BaudrateWeb.Admin.DataExportsLive do
  @moduledoc """
  Admin view of data export requests (`/admin/data-exports`, ADR 0023 §19).

  Read-only. It lists who requested an export, how (self-service or SysOp,
  with the operator), its status, and how many times it was downloaded, so an
  admin can spot unusual export activity. It is **admin-only**. Moderators
  cannot see it, which is also why exports are not recorded in the moderation
  log. There is deliberately no way to trigger an export for another user
  from here.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.DataPortability
  alias BaudrateWeb.DataExportLive

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       wide_layout: true,
       page_title: gettext("Data Exports"),
       requests: DataPortability.list_export_requests(limit: 100)
     )}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp source_label("sysop"), do: gettext("SysOp")
  defp source_label(_), do: gettext("Self-service")

  defp status_label(status), do: DataExportLive.status_label(status)
  defp cancel_reason_label(reason), do: DataExportLive.cancel_reason_label(reason)
end
