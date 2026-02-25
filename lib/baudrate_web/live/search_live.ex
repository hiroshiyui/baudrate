defmodule BaudrateWeb.SearchLive do
  @moduledoc """
  LiveView for full-text search across articles and comments.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Search query, active tab, and pagination state live in the URL via
  `?q=...&tab=...&page=N`.

  Supports dual-strategy search: tsvector for English, trigram ILIKE for CJK.

  When the query matches `@user@domain` or an `https://` actor URL,
  performs a remote actor lookup via WebFinger/ActivityPub and displays
  a follow/unfollow card alongside local search results.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Federation
  alias Baudrate.Federation.{Delivery, Publisher}
  alias BaudrateWeb.RateLimits
  import BaudrateWeb.Helpers, only: [parse_page: 1, parse_id: 1]

  @impl true
  def mount(_params, _session, socket) do
    peer_ip =
      if connected?(socket) do
        case get_connect_info(socket, :peer_data) do
          %{address: addr} -> addr |> :inet.ntoa() |> to_string()
          _ -> "unknown"
        end
      else
        "unknown"
      end

    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:tab, "articles")
     |> assign(:articles, [])
     |> assign(:comments, [])
     |> assign(:total, 0)
     |> assign(:page, 1)
     |> assign(:total_pages, 1)
     |> assign(:peer_ip, peer_ip)
     |> assign(:remote_actor, nil)
     |> assign(:remote_actor_loading, false)
     |> assign(:follow_state, nil)
     |> assign(:page_title, gettext("Search"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params["q"] || ""
    tab = if params["tab"] in ["articles", "comments"], do: params["tab"], else: "articles"
    page = parse_page(params["page"])

    socket =
      socket
      |> assign(:remote_actor, nil)
      |> assign(:remote_actor_loading, false)
      |> assign(:follow_state, nil)

    if query != "" do
      case check_search_rate(socket) do
        {:error, :rate_limited} ->
          {:noreply,
           socket
           |> assign(:query, query)
           |> assign(:tab, tab)
           |> put_flash(:error, gettext("Too many searches. Please try again later."))}

        :ok ->
          result =
            case tab do
              "articles" ->
                Content.search_articles(query, page: page, user: socket.assigns.current_user)

              "comments" ->
                Content.search_comments(query, page: page, user: socket.assigns.current_user)
            end

          socket =
            socket
            |> assign(:query, query)
            |> assign(:tab, tab)
            |> assign_search_results(tab, result)

          # Trigger async remote actor lookup if query looks like a fediverse handle or URL
          socket =
            if remote_actor_query?(query) && connected?(socket) do
              send(self(), {:lookup_remote_actor, query})
              assign(socket, :remote_actor_loading, true)
            else
              socket
            end

          {:noreply, socket}
      end
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

  @impl true
  def handle_event("follow", %{"id" => id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("You are not signed in."))}

      user ->
        with {:ok, remote_actor_id} <- parse_id(id),
             remote_actor when not is_nil(remote_actor) <-
               Baudrate.Repo.get(Federation.RemoteActor, remote_actor_id),
             :ok <- RateLimits.check_outbound_follow(user.id),
             {:ok, follow} <- Federation.create_user_follow(user, remote_actor) do
          {activity, actor_uri} = Publisher.build_follow(user, remote_actor, follow.ap_id)
          Delivery.deliver_follow(activity, remote_actor, actor_uri)

          {:noreply,
           socket
           |> assign(:follow_state, "pending")
           |> put_flash(:info, gettext("Follow request sent."))}
        else
          {:error, :rate_limited} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Follow rate limit exceeded. Please try again later.")
             )}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, gettext("Already following this actor."))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Could not follow actor."))}
        end
    end
  end

  @impl true
  def handle_event("unfollow", %{"id" => id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("You are not signed in."))}

      user ->
        with {:ok, remote_actor_id} <- parse_id(id),
             remote_actor when not is_nil(remote_actor) <-
               Baudrate.Repo.get(Federation.RemoteActor, remote_actor_id),
             follow when not is_nil(follow) <-
               Federation.get_user_follow(user.id, remote_actor_id) do
          follow = Baudrate.Repo.preload(follow, :remote_actor)
          {activity, actor_uri} = Publisher.build_undo_follow(user, follow)
          Delivery.deliver_follow(activity, remote_actor, actor_uri)
          Federation.delete_user_follow(user, remote_actor)

          {:noreply,
           socket
           |> assign(:follow_state, nil)
           |> put_flash(:info, gettext("Unfollowed successfully."))}
        else
          _ ->
            {:noreply, put_flash(socket, :error, gettext("Could not unfollow actor."))}
        end
    end
  end

  @impl true
  def handle_info({:lookup_remote_actor, query}, socket) do
    case Federation.lookup_remote_actor(query) do
      {:ok, remote_actor} ->
        follow_state =
          case socket.assigns.current_user do
            %{id: user_id} ->
              case Federation.get_user_follow(user_id, remote_actor.id) do
                %{state: state} -> state
                nil -> nil
              end

            nil ->
              nil
          end

        {:noreply,
         socket
         |> assign(:remote_actor, remote_actor)
         |> assign(:remote_actor_loading, false)
         |> assign(:follow_state, follow_state)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:remote_actor, nil)
         |> assign(:remote_actor_loading, false)}
    end
  end

  defp remote_actor_query?(query) do
    # Match @user@domain or user@domain (without /) or https:// actor URLs
    cond do
      String.starts_with?(query, "https://") -> true
      String.contains?(query, "@") && !String.contains?(query, "/") -> true
      true -> false
    end
  end

  defp check_search_rate(socket) do
    case socket.assigns.current_user do
      %{id: user_id} -> RateLimits.check_search(user_id)
      nil -> RateLimits.check_search_by_ip(socket.assigns.peer_ip)
    end
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
