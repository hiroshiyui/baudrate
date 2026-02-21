defmodule BaudrateWeb.BoardLive do
  @moduledoc """
  LiveView for displaying a single board and its articles.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Guests can only view public boards; private boards redirect to `/login`.
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
      articles = Content.list_articles_for_board(board)

      can_create =
        if current_user, do: Auth.can_create_content?(current_user), else: false

      {:ok, assign(socket, board: board, articles: articles, can_create: can_create)}
    end
  end
end
