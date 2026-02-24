defmodule BaudrateWeb.UnreadDmCountHook do
  @moduledoc """
  LiveView `attach_hook` that keeps `@unread_dm_count` up to date in real time.

  Subscribes to the user's DM PubSub topic on connected mount and intercepts
  `:dm_received` and `:dm_read` events to re-fetch the unread count from the
  database. Returns `{:cont, socket}` so the underlying LiveView's
  `handle_info` still fires for those events.

  Attach via `attach(socket, user)` in `on_mount` callbacks.
  """

  import Phoenix.LiveView

  alias Baudrate.Messaging
  alias Baudrate.Messaging.PubSub, as: MessagingPubSub

  @doc """
  Subscribes to user DM events (when connected) and attaches a `:handle_info`
  hook that updates `@unread_dm_count` on `:dm_received` / `:dm_read`.

  Returns the socket unchanged if the lifecycle system is not initialized
  (e.g. in unit tests with bare `%Socket{}`).
  """
  def attach(%{private: %{lifecycle: _}} = socket, %{id: user_id} = _user) do
    if connected?(socket) do
      MessagingPubSub.subscribe_user(user_id)
    end

    attach_hook(socket, :unread_dm_count, :handle_info, &handle_info/2)
  end

  def attach(socket, _user), do: socket

  defp handle_info({event, _payload}, socket) when event in [:dm_received, :dm_read] do
    count = Messaging.unread_count(socket.assigns.current_user)
    {:cont, Phoenix.Component.assign(socket, :unread_dm_count, count)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}
end
