defmodule BaudrateWeb.BoardLive do
  @moduledoc """
  LiveView for displaying a single board and its articles.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Access is controlled by `min_role_to_view` — users with insufficient role
  are redirected to `/` (authenticated) or `/login` (guest).
  Articles are paginated via `?page=N` query parameter.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Content.PubSub, as: ContentPubSub
  import BaudrateWeb.Helpers, only: [parse_page: 1]

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    board = Content.get_board_by_slug!(slug)
    current_user = socket.assigns.current_user

    if not Content.can_view_board?(board, current_user) do
      redirect_to = if current_user, do: ~p"/", else: ~p"/login"
      {:ok, redirect(socket, to: redirect_to)}
    else
      if connected?(socket), do: ContentPubSub.subscribe_board(board.id)

      can_create = Content.can_post_in_board?(board, current_user)
      can_manage_follows = board.ap_enabled && Content.board_moderator?(board, current_user)
      ancestors = Content.board_ancestors(board)
      sub_boards = Content.list_visible_sub_boards(board, current_user)

      feed_slug = if board.min_role_to_view == "guest", do: board.slug

      {:ok,
       assign(socket,
         board: board,
         can_create: can_create,
         can_manage_follows: can_manage_follows,
         ancestors: ancestors,
         sub_boards: sub_boards,
         page_title: board.name,
         feed_board_slug: feed_slug
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])

    %{articles: articles, page: page, total_pages: total_pages} =
      Content.paginate_articles_for_board(socket.assigns.board,
        page: page,
        user: socket.assigns.current_user
      )

    {:noreply, assign(socket, articles: articles, page: page, total_pages: total_pages)}
  end

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [
             :article_created,
             :article_deleted,
             :article_updated,
             :article_pinned,
             :article_unpinned,
             :article_locked,
             :article_unlocked
           ] do
    %{articles: articles, page: page, total_pages: total_pages} =
      Content.paginate_articles_for_board(socket.assigns.board,
        page: socket.assigns.page,
        user: socket.assigns.current_user
      )

    {:noreply, assign(socket, articles: articles, page: page, total_pages: total_pages)}
  end
end
