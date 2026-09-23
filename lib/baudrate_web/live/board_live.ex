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
  alias Baudrate.Content.Board
  alias Baudrate.Content.PubSub, as: ContentPubSub
  alias BaudrateWeb.LinkedData
  alias BaudrateWeb.OpenGraph
  alias BaudrateWeb.InteractionHelpers
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
      can_moderate = Content.board_moderator?(board, current_user)
      can_manage_follows = board.ap_enabled && can_moderate
      ancestors = Content.board_ancestors(board)
      sub_boards = Content.list_visible_sub_boards(board, current_user)
      board_moderators = Content.list_board_moderators(board)

      sub_board_ids = Enum.map(sub_boards, & &1.id)
      unread_sub_board_ids = Content.unread_board_ids(current_user, sub_board_ids)

      syndication_slug = if Board.public?(board), do: board.slug

      parent_slug =
        case ancestors do
          [_ | _] -> List.last(ancestors).slug
          _ -> nil
        end

      jsonld =
        LinkedData.board_jsonld(board, parent_slug: parent_slug) |> LinkedData.encode_jsonld()

      dc_meta = LinkedData.dublin_core_meta(:board, board)

      {:ok,
       assign(socket,
         board: board,
         board_moderators: board_moderators,
         can_create: can_create,
         can_moderate: can_moderate,
         can_manage_follows: can_manage_follows,
         ancestors: ancestors,
         sub_boards: sub_boards,
         unread_sub_board_ids: unread_sub_board_ids,
         watched: Content.board_watched?(current_user, board.id),
         page_title: board.name,
         syndication_board_slug: syndication_slug,
         federation_enabled: Baudrate.Setup.federation_enabled?(),
         linked_data_json: jsonld,
         dc_meta: dc_meta,
         og_meta: OpenGraph.board_tags(board)
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_articles(socket, parse_page(params["page"]))}
  end

  @impl true
  def handle_event("show_new_articles", _params, socket) do
    # From a later page, patch back to the first — `handle_params` loads it,
    # and the URL loses its `?page=N`. On the first page, just reload it.
    socket =
      if socket.assigns.page > 1,
        do: push_patch(socket, to: ~p"/boards/#{socket.assigns.board.slug}"),
        else: load_articles(socket, 1)

    {:noreply, push_event(socket, "focus", %{id: "articles"})}
  end

  @impl true
  def handle_event("toggle_watch", _params, %{assigns: %{current_user: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("toggle_watch", _params, socket) do
    %{current_user: user, board: board} = socket.assigns

    case Content.toggle_board_watch(user, board.id) do
      {:ok, _} ->
        {:noreply, assign(socket, :watched, Content.board_watched?(user, board.id))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change whether you watch this."))}
    end
  end

  @impl true
  def handle_event("mark_all_read", _params, socket) do
    current_user = socket.assigns.current_user
    board = socket.assigns.board

    Content.mark_board_read(current_user.id, board.id)

    {:noreply, load_articles(socket, socket.assigns.page)}
  end

  @impl true
  def handle_event("toggle_article_like", %{"id" => id}, socket) do
    InteractionHelpers.handle_toggle_with_counts(
      socket,
      id,
      &Content.toggle_article_like/2,
      &Content.article_like_counts/1,
      :article_liked_ids,
      :article_like_counts,
      InteractionHelpers.article_like_opts()
    )
  end

  @impl true
  def handle_event("toggle_article_boost", %{"id" => id}, socket) do
    InteractionHelpers.handle_toggle_with_counts(
      socket,
      id,
      &Content.toggle_article_boost/2,
      &Content.article_boost_counts/1,
      :article_boosted_ids,
      :article_boost_counts,
      InteractionHelpers.article_boost_opts()
    )
  end

  # A new post is offered, not inserted: reloading the list moved every
  # article under the reader (and under a screen reader's cursor) whenever
  # anybody posted. It counts only posts this viewer's listing would show.
  @impl true
  def handle_info({:article_created, _payload}, socket) do
    %{board: board, arrival_cursor: cursor, current_user: viewer} = socket.assigns
    count = Content.count_new_articles_for_board(board, cursor, viewer)

    socket =
      if count > 0 and count != socket.assigns.new_article_count do
        assign(socket,
          new_article_count: count,
          new_articles_status:
            ngettext(
              "%{count} new post in this board.",
              "%{count} new posts in this board.",
              count
            )
        )
      else
        socket
      end

    {:noreply, socket}
  end

  # These change rows the reader already has — and a moderator's removal
  # should leave the page at once — so they still reload in place.
  @impl true
  def handle_info({event, _payload}, socket)
      when event in [
             :article_deleted,
             :article_updated,
             :article_pinned,
             :article_unpinned,
             :article_locked,
             :article_unlocked
           ] do
    {:noreply, load_articles(socket, socket.assigns.page)}
  end

  # Ignore PubSub messages forwarded by the unread DM / notification count
  # hooks (e.g. :dm_received, :notification_created) for logged-in viewers.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Loads a page of the list. Anything already offered as new is on it now,
  # so the offer resets; the cursor is taken first, so a post arriving in
  # between is counted rather than lost.
  defp load_articles(socket, page) do
    %{board: board, current_user: current_user} = socket.assigns
    cursor = Content.board_arrival_cursor(board)

    result = Content.paginate_articles_for_board(board, page: page, user: current_user)
    article_ids = Enum.map(result.articles, & &1.id)

    {article_liked_ids, article_boosted_ids} =
      if current_user do
        {Content.article_likes_by_user(current_user.id, article_ids),
         Content.article_boosts_by_user(current_user.id, article_ids)}
      else
        {MapSet.new(), MapSet.new()}
      end

    assign(socket,
      articles: result.articles,
      comment_counts: result.comment_counts,
      unread_article_ids: result.unread_article_ids,
      page: result.page,
      total_pages: result.total_pages,
      article_liked_ids: article_liked_ids,
      article_boosted_ids: article_boosted_ids,
      article_like_counts: Content.article_like_counts(article_ids),
      article_boost_counts: Content.article_boost_counts(article_ids),
      arrival_cursor: cursor,
      new_article_count: 0,
      new_articles_status: ""
    )
  end

  defp digest(nil), do: ""

  defp digest(text) do
    plain =
      text
      |> Baudrate.Sanitizer.Native.strip_tags()
      |> Baudrate.Sanitizer.Native.decode_html_entities()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(plain) > 200 do
      String.slice(plain, 0, 200) <> "…"
    else
      plain
    end
  end
end
