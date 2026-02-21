defmodule BaudrateWeb.Admin.UsersLive do
  @moduledoc """
  LiveView for admin user management.

  Only accessible to users with the `"admin"` role. Provides filtering,
  searching, banning/unbanning, role changes, and user approval.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Setup

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user.role.name != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("Access denied."))
       |> redirect(to: ~p"/")}
    else
      roles = Setup.all_roles()
      status_counts = Auth.count_users_by_status()
      users = Auth.list_users()

      {:ok,
       assign(socket,
         users: users,
         status_counts: status_counts,
         status_filter: nil,
         search: "",
         roles: roles,
         ban_target: nil,
         ban_target_username: nil,
         ban_reason: ""
       )}
    end
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    status_filter = if status == "", do: nil, else: status
    {:noreply, socket |> assign(:status_filter, status_filter) |> reload_users()}
  end

  def handle_event("search", %{"search" => term}, socket) do
    {:noreply, socket |> assign(:search, term) |> reload_users()}
  end

  def handle_event("approve", %{"id" => id}, socket) do
    user = Auth.get_user(String.to_integer(id))

    case Auth.approve_user(user) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("User approved successfully."))
         |> reload_users()
         |> reload_counts()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to approve user."))}
    end
  end

  def handle_event("show_ban_modal", %{"id" => id}, socket) do
    user_id = String.to_integer(id)

    if user_id == socket.assigns.current_user.id do
      {:noreply, put_flash(socket, :error, gettext("You cannot ban yourself."))}
    else
      user = Auth.get_user(user_id)

      {:noreply,
       assign(socket,
         ban_target: user_id,
         ban_target_username: user && user.username,
         ban_reason: ""
       )}
    end
  end

  def handle_event("cancel_ban", _params, socket) do
    {:noreply, assign(socket, ban_target: nil, ban_target_username: nil, ban_reason: "")}
  end

  def handle_event("update_ban_reason", %{"reason" => reason}, socket) do
    {:noreply, assign(socket, :ban_reason, reason)}
  end

  def handle_event("confirm_ban", _params, socket) do
    admin_id = socket.assigns.current_user.id
    user = Auth.get_user(socket.assigns.ban_target)
    reason = socket.assigns.ban_reason
    reason = if reason == "", do: nil, else: reason

    case Auth.ban_user(user, admin_id, reason) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(ban_target: nil, ban_target_username: nil, ban_reason: "")
         |> put_flash(:info, gettext("User banned successfully."))
         |> reload_users()
         |> reload_counts()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to ban user."))}
    end
  end

  def handle_event("unban", %{"id" => id}, socket) do
    user = Auth.get_user(String.to_integer(id))

    case Auth.unban_user(user) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("User unbanned successfully."))
         |> reload_users()
         |> reload_counts()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to unban user."))}
    end
  end

  def handle_event("change_role", %{"id" => id, "role_id" => role_id}, socket) do
    admin_id = socket.assigns.current_user.id
    user_id = String.to_integer(id)

    if user_id == admin_id do
      {:noreply, put_flash(socket, :error, gettext("You cannot change your own role."))}
    else
      user = Auth.get_user(user_id)

      case Auth.update_user_role(user, String.to_integer(role_id), admin_id) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("User role updated successfully."))
           |> reload_users()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update user role."))}
      end
    end
  end

  defp reload_users(socket) do
    opts =
      []
      |> then(fn opts ->
        case socket.assigns.status_filter do
          nil -> opts
          status -> Keyword.put(opts, :status, status)
        end
      end)
      |> then(fn opts ->
        case socket.assigns.search do
          "" -> opts
          term -> Keyword.put(opts, :search, term)
        end
      end)

    assign(socket, :users, Auth.list_users(opts))
  end

  defp reload_counts(socket) do
    assign(socket, :status_counts, Auth.count_users_by_status())
  end
end
