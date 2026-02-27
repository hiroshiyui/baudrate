defmodule BaudrateWeb.BookmarksLive do
  @moduledoc """
  LiveView for the bookmarks page (`/bookmarks`).

  Displays a paginated list of bookmarked articles and comments for the
  current user, ordered newest first. Users can remove individual bookmarks.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  import BaudrateWeb.Helpers, only: [parse_page: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Bookmarks"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
    result = Content.list_bookmarks(socket.assigns.current_user.id, page: page)

    {:noreply,
     socket
     |> assign(:bookmarks, result.bookmarks)
     |> assign(:page, result.page)
     |> assign(:total_pages, result.total_pages)}
  end

  @impl true
  def handle_event("remove_bookmark", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    Content.delete_bookmark(user.id, id)

    result = Content.list_bookmarks(user.id, page: socket.assigns.page)

    {:noreply,
     socket
     |> assign(:bookmarks, result.bookmarks)
     |> assign(:total_pages, result.total_pages)
     |> put_flash(:info, gettext("Bookmark removed."))}
  end

  defp bookmark_target_link(bookmark) do
    cond do
      bookmark.article ->
        ~p"/articles/#{bookmark.article.slug}"

      bookmark.comment && bookmark.comment.article ->
        ~p"/articles/#{bookmark.comment.article.slug}"

      true ->
        nil
    end
  end
end
