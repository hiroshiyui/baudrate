defmodule BaudrateWeb.Admin.PendingUsersLive do
  @moduledoc """
  LiveView for admin approval of pending user registrations.

  Only accessible to users with the `"admin"` role. Lists all pending
  users and provides an "Approve" action to activate their accounts.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user.role.name != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("Access denied."))
       |> redirect(to: ~p"/")}
    else
      {:ok, assign(socket, :pending_users, Auth.list_pending_users())}
    end
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    user = Auth.get_user(String.to_integer(id))

    case Auth.approve_user(user) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("User approved successfully."))
         |> assign(:pending_users, Auth.list_pending_users())}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to approve user."))}
    end
  end
end
