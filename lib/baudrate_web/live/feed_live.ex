defmodule BaudrateWeb.FeedLive do
  @moduledoc """
  LiveView for the personal feed page.

  Displays incoming posts from remote actors the user follows.
  Subscribes to `Federation.PubSub` for real-time updates.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Federation
  alias Baudrate.Federation.PubSub, as: FederationPubSub
  import BaudrateWeb.Helpers, only: [parse_page: 1]

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      FederationPubSub.subscribe_user_feed(user.id)
    end

    {:ok, assign(socket, :page_title, gettext("Feed"))}
  end

  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user
    page = parse_page(params["page"])
    result = Federation.list_feed_items(user, page: page)

    {:noreply,
     socket
     |> assign(:items, result.items)
     |> assign(:page, result.page)
     |> assign(:total_pages, result.total_pages)
     |> assign(:total, result.total)}
  end

  def handle_info({:feed_item_created, _payload}, socket) do
    user = socket.assigns.current_user
    page = socket.assigns.page
    result = Federation.list_feed_items(user, page: page)

    {:noreply,
     socket
     |> assign(:items, result.items)
     |> assign(:total_pages, result.total_pages)
     |> assign(:total, result.total)}
  end
end
