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

  @doc """
  The label an action is listed under. Every name in
  `Baudrate.Moderation.Log.valid_actions/0` needs a clause here, or the log
  shows its identifier in every language; `moderation_log_live_test.exs`
  checks.
  """
  def translate_action("ban_user"), do: gettext("Ban User")
  def translate_action("unban_user"), do: gettext("Unban User")
  def translate_action("update_role"), do: gettext("Update Role")
  def translate_action("approve_user"), do: gettext("Approve User")
  def translate_action("reject_user"), do: gettext("Refuse Registration")
  def translate_action("warn_user"), do: gettext("Warn User")
  def translate_action("silence_user"), do: gettext("Silence User")
  def translate_action("suspend_user"), do: gettext("Suspend User")
  def translate_action("lift_sanction"), do: gettext("Lift Sanction")
  def translate_action("resolve_report"), do: gettext("Resolve Report")
  def translate_action("dismiss_report"), do: gettext("Dismiss Report")
  def translate_action("delete_article"), do: gettext("Delete Article")
  def translate_action("delete_comment"), do: gettext("Delete Comment")
  def translate_action("create_board"), do: gettext("Create Board")
  def translate_action("update_board"), do: gettext("Update Board")
  def translate_action("delete_board"), do: gettext("Delete Board")
  def translate_action("block_user"), do: gettext("Block User")
  def translate_action("unblock_user"), do: gettext("Unblock User")
  def translate_action("block_domain"), do: gettext("Block Domain")
  def translate_action("unblock_domain"), do: gettext("Unblock Domain")
  def translate_action("rotate_keys"), do: gettext("Rotate Keys")
  def translate_action("add_board_moderator"), do: gettext("Add Board Moderator")
  def translate_action("remove_board_moderator"), do: gettext("Remove Board Moderator")
  def translate_action("send_flag"), do: gettext("Send Flag")
  def translate_action("edit_article"), do: gettext("Edit Article")
  def translate_action("remove_article_from_board"), do: gettext("Remove Article from Board")
  def translate_action("pin_article"), do: gettext("Pin Article")
  def translate_action("unpin_article"), do: gettext("Unpin Article")
  def translate_action("lock_article"), do: gettext("Lock Article")
  def translate_action("unlock_article"), do: gettext("Unlock Article")
  def translate_action("toggle_board_federation"), do: gettext("Toggle Board Federation")
  def translate_action("update_board_accept_policy"), do: gettext("Update Board Accept Policy")
  def translate_action("update_settings"), do: gettext("Update Settings")
  def translate_action("update_eua"), do: gettext("Update End User Agreement")
  def translate_action("create_rule"), do: gettext("Add Site Rule")
  def translate_action("update_rule"), do: gettext("Edit Site Rule")
  def translate_action("retire_rule"), do: gettext("Retire Site Rule")
  def translate_action("restore_rule"), do: gettext("Restore Site Rule")
  def translate_action("reorder_rules"), do: gettext("Reorder Site Rules")
  def translate_action("update_privacy"), do: gettext("Update Privacy Policy")
  def translate_action("publish_terms_version"), do: gettext("Publish New Terms Version")
  def translate_action("generate_vapid_keys"), do: gettext("Generate Push Keys")
  def translate_action("create_bot"), do: gettext("Create Bot")
  def translate_action("update_bot"), do: gettext("Update Bot")
  def translate_action("delete_bot"), do: gettext("Delete Bot")
  def translate_action("toggle_bot"), do: gettext("Toggle Bot")
  def translate_action("reset_bot_errors"), do: gettext("Reset Bot Errors")
  def translate_action("refresh_bot_favicon"), do: gettext("Refresh Bot Favicon")
  def translate_action("verify_recovery_contact"), do: gettext("Verify Recovery Contact")
  def translate_action("unverify_recovery_contact"), do: gettext("Unverify Recovery Contact")
  def translate_action("issue_recovery_challenge"), do: gettext("Issue Recovery Challenge")
  def translate_action("issue_account_reset"), do: gettext("Issue Account Reset Link")
  def translate_action("revoke_account_reset"), do: gettext("Revoke Account Reset Link")
  def translate_action("clear_second_factors"), do: gettext("Clear Second Factors")
  def translate_action("ban_ip"), do: gettext("Ban IP Address")
  def translate_action("unban_ip"), do: gettext("Lift IP Ban")
  def translate_action("ban_invite_chain"), do: gettext("Ban Invite Chain")
  def translate_action("suspend_remote_actor"), do: gettext("Suspend Remote Account")
  def translate_action("unsuspend_remote_actor"), do: gettext("Lift Remote Account Suspension")
  def translate_action("approve_held_post"), do: gettext("Approve Held Post")
  def translate_action("reject_held_post"), do: gettext("Reject Held Post")
  def translate_action("create_filter"), do: gettext("Create Content Filter")
  def translate_action("update_filter"), do: gettext("Update Content Filter")
  def translate_action("delete_filter"), do: gettext("Delete Content Filter")
  def translate_action("abandon_deliveries"), do: gettext("Abandon Deliveries")
  def translate_action("close_delivery_circuit"), do: gettext("Close Delivery Circuit")
  def translate_action(other), do: other
end
