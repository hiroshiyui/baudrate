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
      notification_icon: 1
    ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      NotificationPubSub.subscribe_user(user.id)
    end

    {:ok, assign(socket, page_title: gettext("Notifications"))}
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
     |> assign(:total_pages, result.total_pages)}
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

  defp actor_name(%{actor_user: %{username: _} = user}), do: BaudrateWeb.Helpers.display_name(user)
  defp actor_name(%{actor_remote_actor: %{username: u, domain: d}}), do: "#{u}@#{d}"
  defp actor_name(_), do: nil

  defp actor_link(%{actor_user: %{username: username}}), do: ~p"/users/#{username}"
  defp actor_link(_), do: nil

  defp target_link(%{article: %{slug: slug}}) when not is_nil(slug), do: ~p"/articles/#{slug}"
  defp target_link(_), do: nil

  defp target_title(%{article: %{title: title}}) when not is_nil(title), do: title
  defp target_title(%{type: "admin_announcement", data: %{"message" => msg}}), do: msg
  defp target_title(_), do: nil

  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{count}m ago", count: div(diff, 60))
      diff < 86_400 -> gettext("%{count}h ago", count: div(diff, 3600))
      diff < 604_800 -> gettext("%{count}d ago", count: div(diff, 86_400))
      true -> BaudrateWeb.Helpers.format_date(datetime)
    end
  end
end
