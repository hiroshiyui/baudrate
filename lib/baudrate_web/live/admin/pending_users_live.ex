defmodule BaudrateWeb.Admin.PendingUsersLive do
  @moduledoc """
  LiveView for admin approval of pending user registrations.

  Only accessible to users with the `"admin"` role. Lists all pending
  users and provides an "Approve" action to activate their accounts.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Auth

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, pending_users: Auth.list_pending_users(), page_title: gettext("Admin Pending Users"))}
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
