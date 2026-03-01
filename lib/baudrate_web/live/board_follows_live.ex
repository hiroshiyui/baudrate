defmodule BaudrateWeb.BoardFollowsLive do
  @moduledoc """
  LiveView for managing board-level outbound follows to remote ActivityPub actors.

  Board moderators and admins can:
  - Toggle the board's accept policy (`open` / `followers_only`)
  - View current board follows with state badges (pending/accepted/rejected)
  - Search for and follow remote actors (`@user@domain` format)
  - Unfollow remote actors

  Accessible at `/boards/:slug/follows` within the `:authenticated` live_session.
  Only board moderators and admins can access this page.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Federation
  alias Baudrate.Federation.{Delivery, Publisher}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    board = Content.get_board_by_slug(slug)

    cond do
      is_nil(board) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Board not found."))
         |> redirect(to: ~p"/")}

      Content.board_moderator?(board, socket.assigns.current_user) ->
        follows = Federation.list_board_follows(board.id)

        {:ok,
         socket
         |> assign(:board, board)
         |> assign(:follows, follows)
         |> assign(:search_query, "")
         |> assign(:search_result, nil)
         |> assign(:search_loading, false)
         |> assign(:search_error, nil)
         |> assign(:page_title, gettext("Board Follows"))}

      true ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You don't have permission to manage this board."))
         |> redirect(to: ~p"/boards/#{slug}")}
    end
  end

  @impl true
  def handle_event("update_policy", %{"policy" => policy}, socket) do
    board = socket.assigns.board

    case Content.update_board(board, %{ap_accept_policy: policy}) do
      {:ok, updated_board} ->
        {:noreply,
         socket
         |> assign(:board, updated_board)
         |> put_flash(:info, gettext("Accept policy updated."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update accept policy."))}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if remote_actor_query?(query) do
      send(self(), {:lookup_remote_actor, query})

      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:search_loading, true)
       |> assign(:search_result, nil)
       |> assign(:search_error, nil)}
    else
      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:search_loading, false)
       |> assign(:search_result, nil)
       |> assign(:search_error, nil)}
    end
  end

  @impl true
  def handle_event("follow", %{"id" => id}, socket) do
    board = socket.assigns.board

    with remote_actor when not is_nil(remote_actor) <-
           Federation.get_remote_actor(id),
         {:ok, board_follow} <- Federation.create_board_follow(board, remote_actor) do
      {activity, actor_uri} =
        Publisher.build_board_follow(board, remote_actor, board_follow.ap_id)

      Delivery.deliver_follow(activity, remote_actor, actor_uri)

      follows = Federation.list_board_follows(board.id)

      {:noreply,
       socket
       |> assign(:follows, follows)
       |> assign(:search_result, nil)
       |> assign(:search_query, "")
       |> put_flash(:info, gettext("Board follow request sent."))}
    else
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Remote actor not found."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create board follow."))}
    end
  end

  @impl true
  def handle_event("unfollow", %{"id" => id}, socket) do
    board = socket.assigns.board

    with remote_actor when not is_nil(remote_actor) <-
           Federation.get_remote_actor(id),
         follow when not is_nil(follow) <-
           Federation.get_board_follow_with_actor(board.id, remote_actor.id) do
      {activity, actor_uri} = Publisher.build_board_undo_follow(board, follow)
      Delivery.deliver_follow(activity, remote_actor, actor_uri)
      Federation.delete_board_follow(board, remote_actor)

      follows = Federation.list_board_follows(board.id)

      {:noreply,
       socket
       |> assign(:follows, follows)
       |> put_flash(:info, gettext("Board follow removed."))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not unfollow actor."))}
    end
  end

  @impl true
  def handle_info({:lookup_remote_actor, query}, socket) do
    case Federation.lookup_remote_actor(query) do
      {:ok, remote_actor} ->
        {:noreply,
         socket
         |> assign(:search_result, remote_actor)
         |> assign(:search_loading, false)
         |> assign(:search_error, nil)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:search_result, nil)
         |> assign(:search_loading, false)
         |> assign(:search_error, gettext("Could not find remote actor."))}
    end
  end

  defp remote_actor_query?(query) do
    String.starts_with?(query, "https://") ||
      (String.contains?(query, "@") && !String.contains?(query, "/"))
  end

  defp already_following?(follows, remote_actor_id) do
    Enum.any?(follows, &(&1.remote_actor_id == remote_actor_id))
  end
end
