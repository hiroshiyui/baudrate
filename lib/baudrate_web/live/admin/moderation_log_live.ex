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
  import BaudrateWeb.Helpers, only: [parse_page: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       wide_layout: true,
       action_filter: nil,
       valid_actions: Log.valid_actions(),
       page_title: gettext("Admin Moderation Log")
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
  defp translate_action("block_user"), do: gettext("Block User")
  defp translate_action("unblock_user"), do: gettext("Unblock User")
  defp translate_action("block_domain"), do: gettext("Block Domain")
  defp translate_action("unblock_domain"), do: gettext("Unblock Domain")
  defp translate_action("rotate_keys"), do: gettext("Rotate Keys")
  defp translate_action("add_board_moderator"), do: gettext("Add Board Moderator")
  defp translate_action("remove_board_moderator"), do: gettext("Remove Board Moderator")
  defp translate_action("send_flag"), do: gettext("Send Flag")
  defp translate_action("edit_article"), do: gettext("Edit Article")
  defp translate_action("remove_article_from_board"), do: gettext("Remove Article from Board")
  defp translate_action("pin_article"), do: gettext("Pin Article")
  defp translate_action("unpin_article"), do: gettext("Unpin Article")
  defp translate_action("lock_article"), do: gettext("Lock Article")
  defp translate_action("unlock_article"), do: gettext("Unlock Article")
  defp translate_action("toggle_board_federation"), do: gettext("Toggle Board Federation")
  defp translate_action("update_board_accept_policy"), do: gettext("Update Board Accept Policy")
  defp translate_action("update_settings"), do: gettext("Update Settings")
  defp translate_action("update_eua"), do: gettext("Update End User Agreement")
  defp translate_action("generate_vapid_keys"), do: gettext("Generate Push Keys")
  defp translate_action("create_bot"), do: gettext("Create Bot")
  defp translate_action("update_bot"), do: gettext("Update Bot")
  defp translate_action("delete_bot"), do: gettext("Delete Bot")
  defp translate_action("toggle_bot"), do: gettext("Toggle Bot")
  defp translate_action("reset_bot_errors"), do: gettext("Reset Bot Errors")
  defp translate_action("refresh_bot_favicon"), do: gettext("Refresh Bot Favicon")
  defp translate_action(other), do: other
end
