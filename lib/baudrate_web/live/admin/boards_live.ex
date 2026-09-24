defmodule BaudrateWeb.Admin.BoardsLive do
  @moduledoc """
  LiveView for admin board management.

  Only accessible to users with the `"admin"` role (enforced by the
  `:require_admin` on_mount hook). Provides CRUD operations for boards
  including name, slug, description, permission levels, parent, federation
  toggle, and board moderator management.

  Phase 7C: boards are listed in the order the site shows them and moved
  with **Move up** / **Move down** among their siblings
  (`Content.move_board/2`) rather than by typing a position, and a board's
  articles can be moved to another board (`Content.move_board_articles/3`)
  so the board can be deleted.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation.KeyStore
  alias Baudrate.Moderation
  import BaudrateWeb.Helpers, only: [parse_id: 1, translate_role: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       boards: ordered_boards(socket.assigns.current_user),
       moving_articles_board: nil,
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

        {:noreply,
         assign(socket, show_form: true, editing_board: board, form: to_form(changeset))}

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
  def handle_event("move", %{"id" => id, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    with {:ok, board_id} <- parse_id(id),
         {:ok, board} <- Content.get_board(board_id),
         :ok <- Content.move_board(board, String.to_existing_atom(direction)) do
      Moderation.log_action(socket.assigns.current_user.id, "reorder_boards",
        target_type: "board",
        target_id: board.id,
        details: %{"name" => board.name, "direction" => direction}
      )

      socket = reload_boards(socket)

      {:noreply,
       push_event(socket, "focus", %{id: move_focus_target(socket, board_id, direction)})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("move_articles_prompt", %{"id" => id}, socket) do
    with {:ok, board_id} <- parse_id(id),
         {:ok, board} <- Content.get_board(board_id) do
      {:noreply,
       socket
       |> assign(:moving_articles_board, board)
       |> push_event("focus", %{id: "admin-boards-move-articles-target"})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("move_articles_cancel", _params, socket) do
    {:noreply, assign(socket, :moving_articles_board, nil)}
  end

  def handle_event("move_articles", %{"target_id" => target_id}, socket) do
    from = socket.assigns.moving_articles_board
    user = socket.assigns.current_user

    with %Board{} <- from,
         {:ok, to_id} <- parse_id(target_id),
         {:ok, to} <- Content.get_board(to_id),
         {:ok, count} <- Content.move_board_articles(from, to, user) do
      Moderation.log_action(user.id, "move_board_articles",
        target_type: "board",
        target_id: from.id,
        details: %{"from" => from.name, "to" => to.name, "count" => count}
      )

      {:noreply,
       socket
       |> assign(:moving_articles_board, nil)
       |> put_flash(
         :info,
         ngettext(
           "%{count} article moved from %{from} to %{to}.",
           "%{count} articles moved from %{from} to %{to}.",
           count,
           from: from.name,
           to: to.name
         )
       )
       |> reload_boards()
       |> push_event("focus", %{id: "boards-heading"})}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Failed to move the articles."))}
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

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

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
         |> reload_boards()
         |> push_event("focus", %{id: "boards-heading"})}

      {:error, :protected} ->
        {:noreply, put_flash(socket, :error, gettext("Cannot delete a protected system board."))}

      {:error, :has_articles} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "This board still has articles. Use Move articles to move them to another board first."
           )
         )}

      {:error, :has_children} ->
        {:noreply, put_flash(socket, :error, gettext("Cannot delete board that has sub-boards."))}

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
    assign(socket, :boards, ordered_boards(socket.assigns.current_user))
  end

  # The order the site lists boards in — each board followed by its
  # sub-boards — so Move up and Move down mean what they look like.
  defp ordered_boards(admin) do
    order =
      admin
      |> Content.list_visible_boards()
      |> Enum.with_index()
      |> Map.new(fn {board, index} -> {board.id, index} end)

    Content.list_all_boards()
    |> Enum.sort_by(&Map.get(order, &1.id, map_size(order)))
  end

  # Keep focus on the button that was pressed, or on its twin once the board
  # has reached the end it was moving towards and that button is gone.
  defp move_focus_target(socket, board_id, direction) do
    siblings = siblings_of(socket.assigns.boards, board_id)

    cond do
      direction == "up" and List.first(siblings) == board_id ->
        "admin-boards-move-down-#{board_id}"

      direction == "down" and List.last(siblings) == board_id ->
        "admin-boards-move-up-#{board_id}"

      true ->
        "admin-boards-move-#{direction}-#{board_id}"
    end
  end

  @doc false
  # Ids of the boards sharing `board_id`'s parent, in listed order.
  def siblings_of(boards, board_id) do
    parent_id = Enum.find_value(boards, fn b -> if b.id == board_id, do: b.parent_id end)
    for b <- boards, b.parent_id == parent_id, do: b.id
  end
end
