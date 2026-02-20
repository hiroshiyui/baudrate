defmodule BaudrateWeb.BoardLive do
  @moduledoc """
  LiveView for displaying a single board and its articles.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    board = Content.get_board_by_slug!(slug)
    articles = Content.list_articles_for_board(board)

    {:ok, assign(socket, board: board, articles: articles)}
  end
end
