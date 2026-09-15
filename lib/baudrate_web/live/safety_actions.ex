defmodule BaudrateWeb.SafetyActions do
  @moduledoc """
  Shared LiveView handlers for the controls members use to protect
  themselves: blocking and muting remote accounts, and reporting feed items,
  received direct messages and remote accounts.

  Used by `FeedLive`, `ArticleLive` (remote comments) and `ConversationLive`
  together with `BaudrateWeb.SafetyComponents`. Every action is authorized in
  its context (`Baudrate.Auth` for blocks and mutes, `Baudrate.Moderation`
  for reports); these handlers only add rate limiting and flash messages.
  Blocks and mutes share `RateLimits.check_mute_user/1`, reports use
  `RateLimits.check_create_report/1`.
  """

  import Phoenix.LiveView, only: [put_flash: 3]
  import Phoenix.Component, only: [assign: 2]
  use Gettext, backend: BaudrateWeb.Gettext

  alias Baudrate.{Auth, Federation, Moderation}
  alias BaudrateWeb.RateLimits

  @report_types ~w(feed_item message remote_actor)

  @doc "The report target types handled by `submit_report/2`."
  def report_types, do: @report_types

  @doc """
  What the member filled in on the report dialog: the free-text reason and the
  reason category (P1-D9). Only these two come from the client; the target is
  always taken from server-side assigns.
  """
  @spec report_details(map()) :: %{reason: String.t() | nil, category: String.t() | nil}
  def report_details(params) when is_map(params) do
    %{reason: params["reason"], category: params["category"]}
  end

  @doc """
  Blocks, unblocks, mutes or unmutes the remote actor whose ID the client sent.

  Returns `{:ok, socket}` when the relationship changed and `{:error, socket}`
  otherwise; both carry a flash message.
  """
  @spec remote_actor_action(
          Phoenix.LiveView.Socket.t(),
          :block | :unblock | :mute | :unmute,
          term()
        ) ::
          {:ok | :error, Phoenix.LiveView.Socket.t()}
  def remote_actor_action(socket, action, id) do
    user = socket.assigns.current_user

    with {:ok, actor_id} <- BaudrateWeb.Helpers.parse_id(to_string(id)),
         %{} = actor <- Federation.get_remote_actor(actor_id),
         :ok <- rate_limit(action, user) do
      apply_action(socket, action, user, actor)
    else
      {:error, :rate_limited} ->
        {:error, put_flash(socket, :error, gettext("Too many actions. Please try again later."))}

      _ ->
        {:error, put_flash(socket, :error, gettext("Account not found."))}
    end
  end

  defp rate_limit(action, user) when action in [:block, :mute],
    do: RateLimits.check_mute_user(user.id)

  defp rate_limit(_action, _user), do: :ok

  defp apply_action(socket, :block, user, actor) do
    case Auth.block_remote_actor(user, actor.ap_id) do
      {:ok, _} -> {:ok, put_flash(socket, :info, gettext("Account blocked."))}
      {:error, _} -> {:error, put_flash(socket, :error, gettext("Failed to block account."))}
    end
  end

  defp apply_action(socket, :mute, user, actor) do
    case Auth.mute_remote_actor(user, actor.ap_id) do
      {:ok, _} -> {:ok, put_flash(socket, :info, gettext("Account muted."))}
      {:error, _} -> {:error, put_flash(socket, :error, gettext("Failed to mute account."))}
    end
  end

  defp apply_action(socket, :unblock, user, actor) do
    Auth.unblock_remote_actor(user, actor.ap_id)
    {:ok, put_flash(socket, :info, gettext("Account unblocked."))}
  end

  defp apply_action(socket, :unmute, user, actor) do
    Auth.unmute_remote_actor(user, actor.ap_id)
    {:ok, put_flash(socket, :info, gettext("Account unmuted."))}
  end

  @doc "Initial (closed) report modal assigns."
  def assign_report_modal(socket) do
    assign(socket,
      show_report_modal: false,
      report_target_type: nil,
      report_target_id: nil,
      report_target_label: nil
    )
  end

  @doc "Opens the report modal for the target named in the event params."
  def open_report_modal(socket, %{"type" => type, "id" => id} = params) do
    assign(socket,
      show_report_modal: true,
      report_target_type: type,
      report_target_id: id,
      report_target_label: params["label"]
    )
  end

  @doc """
  Files the open report (a feed item, message or remote actor) through its
  `Moderation` function and closes the modal with a flash message.
  """
  def submit_report(socket, params) do
    details = report_details(params)
    user = socket.assigns.current_user
    %{report_target_type: type, report_target_id: id} = socket.assigns

    result =
      case RateLimits.check_create_report(user.id) do
        :ok -> file_report(type, user, id, details)
        {:error, :rate_limited} -> {:error, :rate_limited}
      end

    socket = assign_report_modal(socket)

    case result do
      {:ok, _report} ->
        put_flash(socket, :info, gettext("Report submitted. Thank you."))

      {:error, :rate_limited} ->
        put_flash(socket, :error, gettext("Too many reports. Please try again later."))

      {:error, :already_reported} ->
        put_flash(socket, :error, gettext("You have already reported this."))

      {:error, _} ->
        put_flash(socket, :error, gettext("Failed to submit report."))
    end
  end

  defp file_report("feed_item", user, id, details),
    do: Moderation.report_feed_item(user, id, details)

  defp file_report("message", user, id, details), do: Moderation.report_message(user, id, details)

  defp file_report("remote_actor", user, id, details),
    do: Moderation.report_remote_actor(user, id, details)

  defp file_report(_type, _user, _id, _details), do: {:error, :not_found}
end
