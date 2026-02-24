defmodule BaudrateWeb.SearchLive do
  @moduledoc """
  LiveView for full-text search across articles and comments.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Search query, active tab, and pagination state live in the URL via
  `?q=...&tab=...&page=N`.

  Supports dual-strategy search: tsvector for English, trigram ILIKE for CJK.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  import BaudrateWeb.Helpers, only: [parse_page: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:tab, "articles")
     |> assign(:articles, [])
     |> assign(:comments, [])
     |> assign(:total, 0)
     |> assign(:page, 1)
     |> assign(:total_pages, 1)
     |> assign(:page_title, gettext("Search"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params["q"] || ""
    tab = if params["tab"] in ["articles", "comments"], do: params["tab"], else: "articles"
    page = parse_page(params["page"])

    if query != "" do
      result =
        case tab do
          "articles" ->
            Content.search_articles(query, page: page, user: socket.assigns.current_user)

          "comments" ->
            Content.search_comments(query, page: page, user: socket.assigns.current_user)
        end

      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:tab, tab)
       |> assign_search_results(tab, result)}
    else
      {:noreply,
       assign(socket,
         query: query,
         tab: tab,
         articles: [],
         comments: [],
         total: 0,
         page: 1,
         total_pages: 1
       )}
    end
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, push_patch(socket, to: ~p"/search?#{%{q: query, tab: socket.assigns.tab}}")}
  end

  defp assign_search_results(socket, "articles", result) do
    socket
    |> assign(:articles, result.articles)
    |> assign(:comments, [])
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
  end

  defp assign_search_results(socket, "comments", result) do
    socket
    |> assign(:articles, [])
    |> assign(:comments, result.comments)
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
  end
end
