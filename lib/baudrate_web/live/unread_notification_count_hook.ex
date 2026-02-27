defmodule BaudrateWeb.UnreadNotificationCountHook do
  @moduledoc """
  LiveView `attach_hook` that keeps `@unread_notification_count` up to date in real time.

  Subscribes to the user's notification PubSub topic on connected mount and
  intercepts `:notification_created`, `:notification_read`, and
  `:notifications_all_read` events to re-fetch the unread count from the
  database. Returns `{:cont, socket}` so the underlying LiveView's
  `handle_info` still fires for those events.

  Attach via `attach(socket, user)` in `on_mount` callbacks.
  """

  import Phoenix.LiveView

  alias Baudrate.Notification
  alias Baudrate.Notification.PubSub, as: NotificationPubSub

  @doc """
  Subscribes to user notification events (when connected) and attaches a
  `:handle_info` hook that updates `@unread_notification_count` on
  `:notification_created` / `:notification_read` / `:notifications_all_read`.

  Returns the socket unchanged if the lifecycle system is not initialized
  (e.g. in unit tests with bare `%Socket{}`).
  """
  def attach(%{private: %{lifecycle: _}} = socket, %{id: user_id} = _user) do
    if connected?(socket) do
      NotificationPubSub.subscribe_user(user_id)
    end

    attach_hook(socket, :unread_notification_count, :handle_info, &handle_info/2)
  end

  def attach(socket, _user), do: socket

  defp handle_info({event, _payload}, socket)
       when event in [:notification_created, :notification_read, :notifications_all_read] do
    count = Notification.unread_count(socket.assigns.current_user.id)
    {:cont, Phoenix.Component.assign(socket, :unread_notification_count, count)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}
end
