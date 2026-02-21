defmodule BaudrateWeb.Admin.BoardsLive do
  @moduledoc """
  LiveView for admin board management.

  Only accessible to users with the `"admin"` role (enforced by the
  `:require_admin` on_mount hook). Provides CRUD operations for boards
  including name, slug, description, visibility, position, parent, and
  federation toggle.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation.KeyStore
  alias Baudrate.Moderation

  @impl true
  def mount(_params, _session, socket) do
    boards = Content.list_all_boards()

    {:ok,
     assign(socket,
       boards: boards,
       editing_board: nil,
       form: nil,
       show_form: false,
       wide_layout: true
     )}
  end

  @impl true
  def handle_event("new", _params, socket) do
    changeset = Content.change_board()
    {:noreply, assign(socket, show_form: true, editing_board: nil, form: to_form(changeset))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    board = Content.get_board!(String.to_integer(id))
    changeset = Board.update_changeset(board, %{})
    {:noreply, assign(socket, show_form: true, editing_board: board, form: to_form(changeset))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing_board: nil, form: nil)}
  end

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

  def handle_event("save", %{"board" => params}, socket) do
    if socket.assigns.editing_board do
      save_edit(socket, params)
    else
      save_new(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    board = Content.get_board!(String.to_integer(id))

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
