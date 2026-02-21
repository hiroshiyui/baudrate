defmodule BaudrateWeb.BoardLive do
  @moduledoc """
  LiveView for displaying a single board and its articles.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Guests can only view public boards; private boards redirect to `/login`.
  Articles are paginated via `?page=N` query parameter.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    board = Content.get_board_by_slug!(slug)
    current_user = socket.assigns.current_user

    if board.visibility == "private" and is_nil(current_user) do
      {:ok, redirect(socket, to: "/login")}
    else
      can_create =
        if current_user, do: Auth.can_create_content?(current_user), else: false

      ancestors = Content.board_ancestors(board)

      sub_boards =
        if current_user,
          do: Content.list_sub_boards(board),
          else: Content.list_public_sub_boards(board)

      {:ok, assign(socket, board: board, can_create: can_create, ancestors: ancestors, sub_boards: sub_boards)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])

    %{articles: articles, page: page, total_pages: total_pages} =
      Content.paginate_articles_for_board(socket.assigns.board, page: page)

    {:noreply, assign(socket, articles: articles, page: page, total_pages: total_pages)}
  end

  defp parse_page(nil), do: 1

  defp parse_page(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end
end
