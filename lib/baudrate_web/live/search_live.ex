defmodule BaudrateWeb.SearchLive do
  @moduledoc """
  LiveView for full-text article search.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Search query and pagination state live in the URL via `?q=...&page=N`.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:articles, [])
     |> assign(:total, 0)
     |> assign(:page, 1)
     |> assign(:total_pages, 1)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params["q"] || ""
    page = parse_page(params["page"])

    if query != "" do
      result = Content.search_articles(query, page: page, user: socket.assigns.current_user)

      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:articles, result.articles)
       |> assign(:total, result.total)
       |> assign(:page, result.page)
       |> assign(:total_pages, result.total_pages)}
    else
      {:noreply, assign(socket, query: query, articles: [], total: 0, page: 1, total_pages: 1)}
    end
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, push_patch(socket, to: ~p"/search?#{%{q: query}}")}
  end

  defp parse_page(nil), do: 1

  defp parse_page(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end
end
