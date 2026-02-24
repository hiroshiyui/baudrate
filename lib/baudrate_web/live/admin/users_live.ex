defmodule BaudrateWeb.Admin.UsersLive do
  @moduledoc """
  LiveView for admin user management.

  Only accessible to users with the `"admin"` role (enforced by the
  `:require_admin` on_mount hook). Provides filtering, searching,
  banning/unbanning, role changes, and user approval.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Auth
  alias Baudrate.Moderation
  alias Baudrate.Setup
  import BaudrateWeb.Helpers, only: [parse_id: 1, parse_page: 1, translate_role: 1]

  @valid_statuses ~w(active pending banned)

  @impl true
  def mount(_params, _session, socket) do
    roles = Setup.all_roles()
    status_counts = Auth.count_users_by_status()

    {:ok,
     assign(socket,
       users: [],
       page: 1,
       total_pages: 1,
       status_counts: status_counts,
       status_filter: nil,
       search: "",
       roles: roles,
       ban_target: nil,
       ban_target_username: nil,
       ban_reason: "",
       wide_layout: true,
       page_title: gettext("Admin Users")
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])

    status_filter =
      case params["status"] do
        s when s in @valid_statuses -> s
        _ -> nil
      end

    search = params["search"] || ""

    {:noreply,
     socket
     |> assign(page: page, status_filter: status_filter, search: search)
     |> reload_users()}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    status_filter =
      cond do
        status == "" -> nil
        status in @valid_statuses -> status
        true -> nil
      end

    {:noreply,
     socket
     |> assign(:status_filter, status_filter)
     |> push_patch(to: users_path(socket.assigns, status_filter, socket.assigns.search, 1))}
  end

  @impl true
  def handle_event("search", %{"search" => term}, socket) do
    {:noreply,
     socket
     |> assign(:search, term)
     |> push_patch(to: users_path(socket.assigns, socket.assigns.status_filter, term, 1))}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, user_id} ->
        case Auth.get_user(user_id) do
          nil ->
            {:noreply, put_flash(socket, :error, gettext("User not found."))}

          user ->
            case Auth.approve_user(user) do
              {:ok, _user} ->
                Moderation.log_action(socket.assigns.current_user.id, "approve_user",
                  target_type: "user",
                  target_id: user.id,
                  details: %{"username" => user.username}
                )

                {:noreply,
                 socket
                 |> put_flash(:info, gettext("User approved successfully."))
                 |> reload_users()
                 |> reload_counts()}

              {:error, _changeset} ->
                {:noreply, put_flash(socket, :error, gettext("Failed to approve user."))}
            end
        end
    end
  end

  @impl true
  def handle_event("show_ban_modal", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, user_id} ->
        if user_id == socket.assigns.current_user.id do
          {:noreply, put_flash(socket, :error, gettext("You cannot ban yourself."))}
        else
          case Auth.get_user(user_id) do
            nil ->
              {:noreply, put_flash(socket, :error, gettext("User not found."))}

            user ->
              {:noreply,
               assign(socket,
                 ban_target: user_id,
                 ban_target_username: user.username,
                 ban_reason: ""
               )}
          end
        end
    end
  end

  @impl true
  def handle_event("cancel_ban", _params, socket) do
    {:noreply, assign(socket, ban_target: nil, ban_target_username: nil, ban_reason: "")}
  end

  @impl true
  def handle_event("update_ban_reason", %{"reason" => reason}, socket) do
    {:noreply, assign(socket, :ban_reason, reason)}
  end

  @impl true
  def handle_event("confirm_ban", _params, socket) do
    case Auth.get_user(socket.assigns.ban_target) do
      nil ->
        {:noreply,
         socket
         |> assign(ban_target: nil, ban_target_username: nil, ban_reason: "")
         |> put_flash(:error, gettext("User not found."))}

      user ->
        admin_id = socket.assigns.current_user.id
        reason = socket.assigns.ban_reason
        reason = if reason == "", do: nil, else: reason

        case Auth.ban_user(user, admin_id, reason) do
          {:ok, _user} ->
            Moderation.log_action(admin_id, "ban_user",
              target_type: "user",
              target_id: user.id,
              details: %{"username" => user.username, "reason" => reason}
            )

            {:noreply,
             socket
             |> assign(ban_target: nil, ban_target_username: nil, ban_reason: "")
             |> put_flash(:info, gettext("User banned successfully."))
             |> reload_users()
             |> reload_counts()}

          {:error, :self_action} ->
            {:noreply, put_flash(socket, :error, gettext("You cannot ban yourself."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to ban user."))}
        end
    end
  end

  @impl true
  def handle_event("unban", %{"id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, user_id} -> do_unban(socket, user_id)
    end
  end

  @impl true
  def handle_event("change_role", %{"id" => id, "role_id" => role_id}, socket) do
    with {:ok, user_id} <- parse_id(id),
         {:ok, parsed_role_id} <- parse_id(role_id) do
      case Auth.get_user(user_id) do
        nil ->
          {:noreply, put_flash(socket, :error, gettext("User not found."))}

        user ->
          admin_id = socket.assigns.current_user.id
          old_role = user.role.name

          case Auth.update_user_role(user, parsed_role_id, admin_id) do
          {:ok, updated_user} ->
            Moderation.log_action(admin_id, "update_role",
              target_type: "user",
              target_id: user.id,
              details: %{"username" => user.username, "old_role" => old_role, "new_role" => updated_user.role.name}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("User role updated successfully."))
             |> reload_users()}

          {:error, :self_action} ->
            {:noreply, put_flash(socket, :error, gettext("You cannot change your own role."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update user role."))}
        end
      end
    else
      :error -> {:noreply, socket}
    end
  end

  defp do_unban(socket, user_id) do
    case Auth.get_user(user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("User not found."))}

      user ->
        case Auth.unban_user(user) do
          {:ok, _user} ->
            Moderation.log_action(socket.assigns.current_user.id, "unban_user",
              target_type: "user",
              target_id: user.id,
              details: %{"username" => user.username}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("User unbanned successfully."))
             |> reload_users()
             |> reload_counts()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to unban user."))}
        end
    end
  end

  defp reload_users(socket) do
    opts =
      [page: socket.assigns.page]
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

    %{users: users, page: page, total_pages: total_pages} = Auth.paginate_users(opts)

    assign(socket, users: users, page: page, total_pages: total_pages)
  end

  defp users_path(_assigns, status_filter, search, page) do
    params =
      %{}
      |> then(fn p -> if status_filter, do: Map.put(p, "status", status_filter), else: p end)
      |> then(fn p -> if search != "", do: Map.put(p, "search", search), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, "page", page), else: p end)

    if params == %{},
      do: ~p"/admin/users",
      else: ~p"/admin/users" <> "?" <> URI.encode_query(params)
  end

  defp reload_counts(socket) do
    assign(socket, :status_counts, Auth.count_users_by_status())
  end

  defp translate_status("active"), do: gettext("active")
  defp translate_status("pending"), do: gettext("pending")
  defp translate_status("banned"), do: gettext("banned")
  defp translate_status(other), do: other

end
