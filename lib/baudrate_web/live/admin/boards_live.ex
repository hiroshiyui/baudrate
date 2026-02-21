defmodule BaudrateWeb.Admin.BoardsLive do
  @moduledoc """
  LiveView for admin board management.

  Only accessible to users with the `"admin"` role. Provides CRUD
  operations for boards including name, slug, description, visibility,
  position, parent, and federation toggle.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation.KeyStore

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user.role.name != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("Access denied."))
       |> redirect(to: ~p"/")}
    else
      boards = Content.list_all_boards()

      {:ok,
       assign(socket,
         boards: boards,
         all_boards: boards,
         editing_board: nil,
         form: nil,
         show_form: false
       )}
    end
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
        {:noreply,
         socket
         |> put_flash(:info, gettext("Board deleted successfully."))
         |> reload_boards()}

      {:error, :has_articles} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot delete board that has articles."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete board."))}
    end
  end

  defp save_new(socket, params) do
    # Normalize empty parent_id to nil
    params = normalize_parent_id(params)

    case Content.create_board(params) do
      {:ok, board} ->
        KeyStore.ensure_board_keypair(board)

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

    case Content.update_board(socket.assigns.editing_board, params) do
      {:ok, _board} ->
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
    boards = Content.list_all_boards()
    assign(socket, boards: boards, all_boards: boards)
  end
end
