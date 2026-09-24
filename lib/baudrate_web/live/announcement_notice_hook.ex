defmodule BaudrateWeb.AnnouncementNoticeHook do
  @moduledoc """
  LiveView `attach_hook` that handles `"dismiss_announcement"` events (7B).

  The announcement notices are rendered by the layout, so their dismiss
  button can fire on any page — a shared hook for the reason
  `RecoveryNoticeHook` gives. Only a member's click reaches the server; a
  guest's dismissal is kept in their browser by the `AnnouncementNoticeHook` JS
  hook and never sent.

  After the notice is removed, focus moves to the main content, since the
  button that had it is gone.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Baudrate.Announcements

  @doc """
  Attaches the hook. Returns the socket unchanged when the lifecycle is not
  initialized (a bare `%Socket{}` in unit tests).
  """
  def attach(%{private: %{lifecycle: _}} = socket) do
    attach_hook(socket, :announcement_notice, :handle_event, &handle_event/3)
  end

  def attach(socket), do: socket

  defp handle_event("dismiss_announcement", %{"id" => id}, socket) do
    with %{} = user <- socket.assigns[:current_user],
         {id, ""} <- Integer.parse(to_string(id)) do
      :ok = Announcements.dismiss(user, id)
      remaining = Enum.reject(socket.assigns[:announcements] || [], &(&1.id == id))

      {:halt,
       socket
       |> assign(:announcements, remaining)
       |> push_event("focus", %{id: "main-content"})}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
