defmodule BaudrateWeb.Admin.ModerationLogLive do
  @moduledoc """
  LiveView for the admin moderation log.

  Displays a paginated, filterable list of moderation actions taken by
  admins and moderators. Only accessible to admin users.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Moderation
  alias Baudrate.Moderation.Log

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       wide_layout: true,
       action_filter: nil,
       valid_actions: Log.valid_actions()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
    action_filter = params["action"]

    opts =
      [page: page]
      |> then(fn opts ->
        if action_filter && action_filter != "",
          do: Keyword.put(opts, :action, action_filter),
          else: opts
      end)

    %{logs: logs, page: page, total_pages: total_pages} =
      Moderation.list_moderation_logs(opts)

    {:noreply,
     assign(socket,
       logs: logs,
       page: page,
       total_pages: total_pages,
       action_filter: action_filter
     )}
  end

  @impl true
  def handle_event("filter", %{"action" => action}, socket) do
    params = if action == "", do: %{}, else: %{"action" => action}
    {:noreply, push_patch(socket, to: ~p"/admin/moderation-log?#{params}")}
  end

  defp parse_page(nil), do: 1

  defp parse_page(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp translate_action("ban_user"), do: gettext("Ban User")
  defp translate_action("unban_user"), do: gettext("Unban User")
  defp translate_action("update_role"), do: gettext("Update Role")
  defp translate_action("approve_user"), do: gettext("Approve User")
  defp translate_action("resolve_report"), do: gettext("Resolve Report")
  defp translate_action("dismiss_report"), do: gettext("Dismiss Report")
  defp translate_action("delete_article"), do: gettext("Delete Article")
  defp translate_action("delete_comment"), do: gettext("Delete Comment")
  defp translate_action("create_board"), do: gettext("Create Board")
  defp translate_action("update_board"), do: gettext("Update Board")
  defp translate_action("delete_board"), do: gettext("Delete Board")
  defp translate_action(other), do: other
end
