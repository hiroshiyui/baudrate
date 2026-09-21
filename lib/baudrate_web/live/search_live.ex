defmodule BaudrateWeb.SearchLive do
  @moduledoc """
  LiveView for full-text search across articles, comments, boards, and local users.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Search query, active tab, and pagination state live in the URL via
  `?q=...&tab=...&page=N`.

  Supports dual-strategy search: tsvector for English, trigram ILIKE for CJK.

  Sort, and the board and date filters, live in the URL too — but only the
  sort has a parameter of its own. **The filter controls write operators into
  `q`** (`board:`, `after:`, `before:`) rather than carrying parallel
  `?board=&from=&to=` parameters, so the query string stays the one description
  of what is being searched and the controls cannot silently disagree with the
  box above them. `Baudrate.Content.SearchQuery` is both the parser and the
  writer.

  They also live inside `#search-form`, so its own button is what applies
  them: one submission is one search is one rate-limit hit.
  `RateLimits.check_search_by_ip/1` is what bounds remote-actor probing
  (ADR 0051), and a `phx-change` on each control would spend that budget four
  times over for a single search. It keeps the filters working with scripting
  switched off, as well.

  When the query matches `@user@domain` or an `https://` actor URL,
  performs a remote actor lookup via WebFinger/ActivityPub and displays
  a follow/unfollow card alongside local search results.

  The "Users" tab searches local users and supports follow/unfollow actions
  for authenticated users.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.SearchQuery
  alias Baudrate.Federation
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.Helpers,
    only: [
      parse_page: 1,
      parse_id: 1,
      translate_role: 1,
      extract_peer_ip: 1,
      translate_visibility: 1,
      translate_actor_type: 1
    ]

  @sorts Content.Search.sorts()
  @default_sort hd(@sorts)

  @impl true
  def mount(_params, _session, socket) do
    peer_ip = if connected?(socket), do: extract_peer_ip(socket), else: "unknown"

    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:tab, "articles")
     |> assign(:sort, @default_sort)
     |> assign(:filter_board, nil)
     |> assign(:filter_from, "")
     |> assign(:filter_to, "")
     |> assign(:filter_board_options, filter_board_options(socket.assigns[:current_user]))
     |> assign(:no_scope, false)
     |> assign(:users_capped, false)
     |> assign(:articles, [])
     |> assign(:comments, [])
     |> assign(:boards, [])
     |> assign(:local_users, [])
     |> assign(:local_user_follow_states, %{})
     |> assign(:total, 0)
     |> assign(:page, 1)
     |> assign(:total_pages, 1)
     |> assign(:peer_ip, peer_ip)
     |> assign(:remote_actor, nil)
     |> assign(:remote_actor_loading, false)
     |> assign(:follow_state, nil)
     |> assign(:remote_object, nil)
     |> assign(:remote_object_loading, false)
     |> assign(:page_title, gettext("Search"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params["q"] || ""

    tab =
      if params["tab"] in ["articles", "comments", "boards", "users"],
        do: params["tab"],
        else: "articles"

    page = parse_page(params["page"])
    sort = parse_sort(params["sort"])
    {text, operators} = SearchQuery.parse(query)

    socket =
      socket
      |> assign(:remote_actor, nil)
      |> assign(:remote_actor_loading, false)
      |> assign(:follow_state, nil)
      |> assign(:remote_object, nil)
      |> assign(:remote_object_loading, false)
      |> assign(:sort, sort)
      |> assign(:filter_board, SearchQuery.first(operators, "board"))
      |> assign(:filter_from, SearchQuery.date_value(operators, "after"))
      |> assign(:filter_to, SearchQuery.date_value(operators, "before"))

    if query != "" do
      case check_search_rate(socket) do
        {:error, :rate_limited} ->
          {:noreply,
           socket
           |> assign(:query, query)
           |> assign(:tab, tab)
           |> put_flash(:error, gettext("Too many searches. Please try again later."))}

        :ok ->
          socket =
            socket
            |> assign(:query, query)
            |> assign(:tab, tab)
            |> assign(
              :no_scope,
              tab in ["articles", "comments"] and not SearchQuery.scoped?(query)
            )

          socket =
            case tab do
              "articles" ->
                result =
                  Content.search_articles(query,
                    page: page,
                    sort: sort,
                    user: socket.assigns.current_user
                  )

                assign_search_results(socket, "articles", result)

              "comments" ->
                result =
                  Content.search_comments(query,
                    page: page,
                    sort: sort,
                    user: socket.assigns.current_user
                  )

                assign_search_results(socket, "comments", result)

              # Boards and users are searched by the free text alone. The
              # operators describe articles, and once the filter controls write
              # `board:` into the query, the raw string would have this tab
              # looking for a board *named* "board:general".
              "boards" ->
                result =
                  Content.search_visible_boards(text,
                    page: page,
                    user: socket.assigns.current_user
                  )

                assign_search_results(socket, "boards", result)

              "users" ->
                search_local_users(socket, text, page)
            end

          # Trigger async remote actor lookup if query looks like a fediverse handle or URL
          socket =
            if remote_actor_query?(query) && connected?(socket) do
              send(self(), {:lookup_remote_actor, query})
              assign(socket, :remote_actor_loading, true)
            else
              socket
            end

          # Trigger async remote object lookup for https:// URLs
          socket =
            if remote_object_query?(query) && connected?(socket) do
              send(self(), {:lookup_remote_object, query})
              assign(socket, :remote_object_loading, true)
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
         no_scope: false,
         users_capped: false,
         articles: [],
         comments: [],
         boards: [],
         local_users: [],
         local_user_follow_states: %{},
         total: 0,
         page: 1,
         total_pages: 1
       )}
    end
  end

  @impl true
  def handle_event("search", params, socket) do
    query =
      (params["q"] || "")
      |> keep_or_put("board", params["filter_board"], socket.assigns.filter_board)
      |> keep_or_put("after", params["filter_from"], socket.assigns.filter_from)
      |> keep_or_put("before", params["filter_to"], socket.assigns.filter_to)

    sort = parse_sort(params["sort"])

    {:noreply,
     push_patch(socket, to: ~p"/search?#{%{q: query, tab: socket.assigns.tab, sort: sort}}")}
  end

  @impl true
  def handle_event("follow", %{"id" => id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("You are not signed in."))}

      user ->
        with {:ok, remote_actor_id} <- parse_id(id),
             remote_actor when not is_nil(remote_actor) <-
               Federation.get_remote_actor(remote_actor_id),
             :ok <- RateLimits.check_outbound_follow(user.id),
             {:ok, _follow} <- Federation.follow_remote_actor(user, remote_actor) do
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

          {:error, :blocked} ->
            {:noreply,
             put_flash(socket, :error, BaudrateWeb.Helpers.blocked_interaction_message())}

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
               Federation.get_remote_actor(remote_actor_id),
             {:ok, _follow} <- Federation.unfollow_remote_actor(user, remote_actor) do
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
  def handle_event("follow_user", %{"id" => id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("You are not signed in."))}

      user ->
        with {:ok, followed_user_id} <- parse_id(id),
             followed_user when not is_nil(followed_user) <-
               Auth.get_user(followed_user_id),
             :ok <- RateLimits.check_outbound_follow(user.id),
             {:ok, _follow} <- Federation.create_local_follow(user, followed_user) do
          follow_states =
            Map.put(socket.assigns.local_user_follow_states, followed_user_id, "accepted")

          {:noreply,
           socket
           |> assign(:local_user_follow_states, follow_states)
           |> put_flash(:info, gettext("Followed successfully."))}
        else
          {:error, :self_follow} ->
            {:noreply, put_flash(socket, :error, gettext("You cannot follow yourself."))}

          {:error, :rate_limited} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Follow rate limit exceeded. Please try again later.")
             )}

          {:error, :blocked} ->
            {:noreply,
             put_flash(socket, :error, BaudrateWeb.Helpers.blocked_interaction_message())}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, gettext("Already following this user."))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Could not follow user."))}
        end
    end
  end

  @impl true
  def handle_event("unfollow_user", %{"id" => id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("You are not signed in."))}

      user ->
        with {:ok, followed_user_id} <- parse_id(id),
             followed_user when not is_nil(followed_user) <-
               Auth.get_user(followed_user_id),
             {:ok, _follow} <- Federation.delete_local_follow(user, followed_user) do
          follow_states =
            Map.delete(socket.assigns.local_user_follow_states, followed_user_id)

          {:noreply,
           socket
           |> assign(:local_user_follow_states, follow_states)
           |> put_flash(:info, gettext("Unfollowed successfully."))}
        else
          _ ->
            {:noreply, put_flash(socket, :error, gettext("Could not unfollow user."))}
        end
    end
  end

  @impl true
  def handle_event("import_remote_object", %{"url" => url}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("You are not signed in."))}

      _user ->
        case Federation.lookup_remote_object(url) do
          {:ok, article} ->
            {:noreply, push_navigate(socket, to: ~p"/articles/#{article.slug}")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not import remote post."))}
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

  @impl true
  def handle_info({:lookup_remote_object, url}, socket) do
    case Federation.fetch_remote_object(url) do
      {:ok, :existing, article} ->
        {:noreply,
         socket
         |> assign(:remote_object, {:existing, article})
         |> assign(:remote_object_loading, false)}

      {:ok, preview} ->
        {:noreply,
         socket
         |> assign(:remote_object, {:preview, preview})
         |> assign(:remote_object_loading, false)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:remote_object, nil)
         |> assign(:remote_object_loading, false)}
    end
  end

  # Ignore PubSub messages forwarded by the unread DM / notification count
  # hooks (e.g. :dm_received, :notification_created) for logged-in viewers.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp remote_actor_query?(query) do
    # Match @user@domain or user@domain (without /) or https:// actor URLs
    cond do
      String.starts_with?(query, "https://") -> true
      String.contains?(query, "@") && !String.contains?(query, "/") -> true
      true -> false
    end
  end

  defp remote_object_query?(query) do
    String.starts_with?(query, "https://")
  end

  defp check_search_rate(socket) do
    case socket.assigns.current_user do
      %{id: user_id} -> RateLimits.check_search(user_id)
      nil -> RateLimits.check_search_by_ip(socket.assigns.peer_ip)
    end
  end

  defp search_local_users(socket, "", _page) do
    socket
    |> assign(:local_users, [])
    |> assign(:local_user_follow_states, %{})
    |> assign(:articles, [])
    |> assign(:comments, [])
    |> assign(:boards, [])
    |> assign(:total, 0)
    |> assign(:page, 1)
    |> assign(:total_pages, 1)
    |> assign(:users_capped, false)
  end

  defp search_local_users(socket, query, page) do
    current_user = socket.assigns.current_user
    exclude_id = if current_user, do: current_user.id, else: nil

    result = Auth.search_users_page(query, page: page, exclude_id: exclude_id)

    follow_states =
      if current_user do
        user_ids = Enum.map(result.users, & &1.id)
        Federation.batch_local_follow_states(current_user.id, user_ids)
      else
        %{}
      end

    socket
    |> assign(:local_users, result.users)
    |> assign(:local_user_follow_states, follow_states)
    |> assign(:articles, [])
    |> assign(:comments, [])
    |> assign(:boards, [])
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:users_capped, result.capped)
  end

  # Never `String.to_atom/1` on a query parameter: the three sorts are matched
  # by name and anything else is the default.
  # A control that was not touched leaves its operator exactly as the reader
  # typed it. Writing unconditionally would quietly drop the second of two
  # `board:` operators, since a single-choice control can only show the first.
  defp keep_or_put(query, _key, submitted, current)
       when submitted in [nil, ""] and current in [nil, ""],
       do: query

  defp keep_or_put(query, _key, submitted, current) when submitted == current, do: query
  defp keep_or_put(query, key, submitted, _current), do: SearchQuery.put(query, key, submitted)

  defp parse_sort(value) do
    Enum.find(@sorts, @default_sort, &(to_string(&1) == value))
  end

  @doc false
  def sort_options, do: @sorts

  @doc false
  def sort_label(:relevance), do: gettext("Relevance")
  def sort_label(:newest), do: gettext("Newest first")
  def sort_label(:oldest), do: gettext("Oldest first")

  defp filter_board_options(user) do
    boards = Content.list_visible_boards(user)
    names = Map.new(boards, &{&1.id, &1.name})

    Enum.map(boards, fn board ->
      case board.parent_id && Map.get(names, board.parent_id) do
        nil -> {board.name, board.slug}
        parent -> {parent <> " › " <> board.name, board.slug}
      end
    end)
  end

  defp assign_search_results(socket, "articles", result) do
    socket
    |> assign(:articles, result.articles)
    |> assign(:comments, [])
    |> assign(:boards, [])
    |> assign(:local_users, [])
    |> assign(:local_user_follow_states, %{})
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
  end

  defp assign_search_results(socket, "comments", result) do
    socket
    |> assign(:articles, [])
    |> assign(:comments, result.comments)
    |> assign(:boards, [])
    |> assign(:local_users, [])
    |> assign(:local_user_follow_states, %{})
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
  end

  defp assign_search_results(socket, "boards", result) do
    socket
    |> assign(:articles, [])
    |> assign(:comments, [])
    |> assign(:boards, result.boards)
    |> assign(:local_users, [])
    |> assign(:local_user_follow_states, %{})
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
  end
end
