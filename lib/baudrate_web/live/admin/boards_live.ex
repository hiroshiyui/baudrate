defmodule BaudrateWeb.Admin.BoardsLive do
  @moduledoc """
  LiveView for admin board management.

  Only accessible to users with the `"admin"` role (enforced by the
  `:require_admin` on_mount hook). Provides CRUD operations for boards
  including name, slug, description, permission levels, position, parent,
  federation toggle, and board moderator management.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation.KeyStore
  alias Baudrate.Moderation
  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @impl true
  def mount(_params, _session, socket) do
    boards = Content.list_all_boards()

    {:ok,
     assign(socket,
       boards: boards,
       editing_board: nil,
       form: nil,
       show_form: false,
       wide_layout: true,
       managing_moderators_board: nil,
       board_moderators: [],
       active_users: [],
       mod_search_query: "",
       page_title: gettext("Admin Boards")
     )}
  end

  @impl true
  def handle_event("new", _params, socket) do
    changeset = Content.change_board()
    {:noreply, assign(socket, show_form: true, editing_board: nil, form: to_form(changeset))}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, board_id} ->
        board = Content.get_board!(board_id)
        changeset = Board.update_changeset(board, %{})
        {:noreply, assign(socket, show_form: true, editing_board: board, form: to_form(changeset))}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing_board: nil, form: nil)}
  end

  @impl true
  def handle_event("validate", %{"board" => params}, socket) do
    changeset =
      if socket.assigns.editing_board do
        Board.update_changeset(socket.assigns.editing_board, params)
      else
        Board.changeset(%Board{}, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"board" => params}, socket) do
    if socket.assigns.editing_board do
      save_edit(socket, params)
    else
      save_new(socket, params)
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, board_id} -> do_delete_board(socket, board_id)
    end
  end

  @impl true
  def handle_event("manage_moderators", %{"id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, board_id} -> do_manage_moderators(socket, board_id)
    end
  end

  @impl true
  def handle_event("close_moderators", _params, socket) do
    {:noreply,
     assign(socket,
       managing_moderators_board: nil,
       board_moderators: [],
       active_users: [],
       mod_search_query: ""
     )}
  end

  @impl true
  def handle_event("search_mod_users", %{"search" => %{"query" => query}}, socket) do
    query = String.trim(query)

    if String.length(query) < 2 do
      {:noreply, assign(socket, active_users: [], mod_search_query: query)}
    else
      users = Auth.search_users(query, limit: 20)
      {:noreply, assign(socket, active_users: users, mod_search_query: query)}
    end
  end

  @impl true
  def handle_event("add_moderator", %{"user_id" => user_id}, socket) do
    case parse_id(user_id) do
      :error ->
        {:noreply, socket}

      {:ok, uid} ->
        board = socket.assigns.managing_moderators_board

        case Content.add_board_moderator(board.id, uid) do
          {:ok, _} ->
            Moderation.log_action(socket.assigns.current_user.id, "add_board_moderator",
              target_type: "board",
              target_id: board.id,
              details: %{"board_name" => board.name, "user_id" => uid}
            )

            moderators = Content.list_board_moderators(board)
            {:noreply, assign(socket, board_moderators: moderators)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to add moderator."))}
        end
    end
  end

  @impl true
  def handle_event("remove_moderator", %{"user-id" => user_id}, socket) do
    case parse_id(user_id) do
      :error ->
        {:noreply, socket}

      {:ok, uid} ->
        board = socket.assigns.managing_moderators_board

        Content.remove_board_moderator(board.id, uid)

        Moderation.log_action(socket.assigns.current_user.id, "remove_board_moderator",
          target_type: "board",
          target_id: board.id,
          details: %{"board_name" => board.name, "user_id" => uid}
        )

        moderators = Content.list_board_moderators(board)
        {:noreply, assign(socket, board_moderators: moderators)}
    end
  end

  defp do_delete_board(socket, board_id) do
    board = Content.get_board!(board_id)

    case Content.delete_board(board) do
      {:ok, _board} ->
        Moderation.log_action(socket.assigns.current_user.id, "delete_board",
          target_type: "board",
          target_id: board.id,
          details: %{"name" => board.name, "slug" => board.slug}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Board deleted successfully."))
         |> reload_boards()}

      {:error, :protected} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot delete a protected system board."))}

      {:error, :has_articles} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot delete board that has articles."))}

      {:error, :has_children} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot delete board that has sub-boards."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete board."))}
    end
  end

  defp do_manage_moderators(socket, board_id) do
    board = Content.get_board!(board_id)
    moderators = Content.list_board_moderators(board)

    {:noreply,
     assign(socket,
       managing_moderators_board: board,
       board_moderators: moderators,
       active_users: [],
       mod_search_query: ""
     )}
  end

  defp save_new(socket, params) do
    params = normalize_parent_id(params)

    case Content.create_board(params) do
      {:ok, board} ->
        KeyStore.ensure_board_keypair(board)

        Moderation.log_action(socket.assigns.current_user.id, "create_board",
          target_type: "board",
          target_id: board.id,
          details: %{"name" => board.name, "slug" => board.slug}
        )

        {:noreply,
         socket
         |> assign(show_form: false, editing_board: nil, form: nil)
         |> put_flash(:info, gettext("Board created successfully."))
         |> reload_boards()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_edit(socket, params) do
    params = normalize_parent_id(params)
    board = Content.get_board!(socket.assigns.editing_board.id)

    case Content.update_board(board, params) do
      {:ok, updated_board} ->
        Moderation.log_action(socket.assigns.current_user.id, "update_board",
          target_type: "board",
          target_id: board.id,
          details: %{"name" => updated_board.name}
        )

        {:noreply,
         socket
         |> assign(show_form: false, editing_board: nil, form: nil)
         |> put_flash(:info, gettext("Board updated successfully."))
         |> reload_boards()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp normalize_parent_id(%{"parent_id" => ""} = params), do: Map.put(params, "parent_id", nil)
  defp normalize_parent_id(params), do: params

  defp reload_boards(socket) do
    assign(socket, :boards, Content.list_all_boards())
  end
end
