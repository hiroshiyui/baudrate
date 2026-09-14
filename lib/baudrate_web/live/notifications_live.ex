defmodule BaudrateWeb.NotificationsLive do
  @moduledoc """
  LiveView for the notifications page (`/notifications`).

  Displays a paginated list of notifications for the current user, ordered
  newest first. Users can mark individual notifications as read or mark all
  as read. Subscribes to `Notification.PubSub` for real-time updates.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Notification
  alias Baudrate.Notification.PubSub, as: NotificationPubSub

  import BaudrateWeb.Helpers,
    only: [
      parse_page: 1,
      notification_text: 1,
      notification_icon: 1,
      format_relative_time: 1
    ]

  @security_types Baudrate.Notification.Notification.security_types()

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      NotificationPubSub.subscribe_user(user.id)
    end

    {:ok, assign(socket, page_title: gettext("Notifications"), live_status: "")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user
    page = parse_page(params["page"])
    result = Notification.list_notifications(user.id, page: page)

    {:noreply,
     socket
     |> assign(:notifications, result.notifications)
     |> assign(:page, result.page)
     |> assign(:total_pages, result.total_pages)}
  end

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:notification_created, :notification_read, :notifications_all_read] do
    user = socket.assigns.current_user
    page = socket.assigns.page
    result = Notification.list_notifications(user.id, page: page)

    {:noreply,
     socket
     |> assign(:notifications, result.notifications)
     |> assign(:total_pages, result.total_pages)
     |> maybe_announce(event, user.id)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    user_id = user.id

    case Notification.get_notification(id) do
      %{user_id: ^user_id} = notif ->
        Notification.mark_as_read(notif)

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_event("mark_all_read", _params, socket) do
    user = socket.assigns.current_user
    Notification.mark_all_as_read(user.id)
    {:noreply, socket}
  end

  # Screen readers do not notice a silently re-rendered list, so a newly
  # arrived notification is announced through the page's `role="status"` node.
  defp maybe_announce(socket, :notification_created, user_id) do
    count = Notification.unread_count(user_id)

    assign(
      socket,
      :live_status,
      ngettext(
        "New notification. %{count} unread notification",
        "New notification. %{count} unread notifications",
        count,
        count: count
      )
    )
  end

  defp maybe_announce(socket, _event, _user_id), do: socket

  defp actor_name(%{actor_user: %{username: _} = user}),
    do: BaudrateWeb.Helpers.display_name(user)

  defp actor_name(%{actor_remote_actor: %{username: u, domain: d}}), do: "#{u}@#{d}"
  defp actor_name(_), do: nil

  defp actor_link(%{actor_user: %{username: username}}), do: ~p"/users/#{username}"
  defp actor_link(_), do: nil

  defp target_link(%{article: %{slug: slug}}) when not is_nil(slug), do: ~p"/articles/#{slug}"
  defp target_link(%{type: "data_export_" <> _}), do: ~p"/profile/export"
  defp target_link(%{type: "totp_login_failed"}), do: ~p"/profile/password"
  defp target_link(%{type: "account_" <> _}), do: ~p"/profile/move"
  defp target_link(%{type: type}) when type in @security_types, do: ~p"/profile"
  defp target_link(_), do: nil

  defp target_title(%{article: %{title: title}}) when not is_nil(title), do: title
  defp target_title(%{type: "admin_announcement", data: %{"message" => msg}}), do: msg

  defp target_title(%{type: "actor_moved", data: %{"label" => label}}) when label != "",
    do: gettext("New account: %{label}", label: label)

  defp target_title(%{type: type, data: %{"label" => label}})
       when type in ["security_key_added", "security_key_removed"] and label != "",
       do: gettext("Security key: %{label}", label: label)

  defp target_title(%{type: type, data: %{"label" => label}})
       when type in ["account_alias_added", "account_alias_removed"] and label != "",
       do: gettext("Alias: %{label}", label: label)

  defp target_title(%{type: "account_move_" <> _, data: %{"label" => label}}) when label != "",
    do: gettext("Destination: %{label}", label: label)

  defp target_title(%{type: "data_export_" <> _}), do: gettext("Review your data exports")
  defp target_title(%{type: "totp_login_failed"}), do: gettext("Change your password")

  defp target_title(%{type: type}) when type in @security_types,
    do: gettext("Review your security settings")

  defp target_title(_), do: nil

  defp security_notice?(%{type: type}), do: type in @security_types

  # This notice is not about a change the user made, so the usual hint does not fit.
  defp security_hint(%{type: "totp_login_failed"}),
    do:
      gettext(
        "If this was not you, your password is known to someone else. Change it right away and contact an administrator."
      )

  defp security_hint(_),
    do:
      gettext(
        "If you did not make this change, check your security settings right away and contact an administrator."
      )
end
