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
  The board must be federated (`ap_enabled == true` and `min_role_to_view == "guest"`)
  to ensure remote instances can fetch the board actor for signature verification.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.{Delivery, KeyStore, Publisher}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    board = Content.get_board_by_slug(slug)

    cond do
      is_nil(board) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Board not found."))
         |> redirect(to: ~p"/")}

      not Content.board_moderator?(board, socket.assigns.current_user) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You don't have permission to manage this board."))
         |> redirect(to: ~p"/boards/#{slug}")}

      not Board.federated?(board) ->
        {:ok,
         socket
         |> put_flash(
           :error,
           gettext(
             "This board is not federated. Enable federation and set visibility to public first."
           )
         )
         |> redirect(to: ~p"/boards/#{slug}")}

      true ->
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

    cond do
      local_actor_query?(query) ->
        {:noreply,
         socket
         |> assign(:search_query, query)
         |> assign(:search_loading, false)
         |> assign(:search_result, nil)
         |> assign(
           :search_error,
           gettext(
             "This is a local user. To have a bot post to this board, configure the bot's target boards in Admin → Bots."
           )
         )}

      remote_actor_query?(query) ->
        send(self(), {:lookup_remote_actor, query})

        {:noreply,
         socket
         |> assign(:search_query, query)
         |> assign(:search_loading, true)
         |> assign(:search_result, nil)
         |> assign(:search_error, nil)}

      true ->
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
         {:ok, board} <- KeyStore.ensure_board_keypair(board),
         {:ok, board_follow} <- Federation.create_board_follow(board, remote_actor) do
      {activity, actor_uri} =
        Publisher.build_board_follow(board, remote_actor, board_follow.ap_id)

      Delivery.deliver_follow(activity, remote_actor, actor_uri)

      follows = Federation.list_board_follows(board.id)

      {:noreply,
       socket
       |> assign(:board, board)
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
         {:ok, board} <- KeyStore.ensure_board_keypair(board),
         follow when not is_nil(follow) <-
           Federation.get_board_follow_with_actor(board.id, remote_actor.id) do
      {activity, actor_uri} = Publisher.build_board_undo_follow(board, follow)
      Delivery.deliver_follow(activity, remote_actor, actor_uri)
      Federation.delete_board_follow(board, remote_actor)

      follows = Federation.list_board_follows(board.id)

      {:noreply,
       socket
       |> assign(:board, board)
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

  # Returns true when the query refers to a local user account:
  # - bare "@username" with no domain component
  # - "@username@<local_host>" where local_host matches this instance
  defp local_actor_query?(query) do
    local_host = URI.parse(BaudrateWeb.Endpoint.url()).host

    cond do
      # "@username" — no domain at all
      Regex.match?(~r/^@[a-zA-Z0-9_]+$/, query) ->
        true

      # "@username@local_host"
      Regex.match?(~r/^@[a-zA-Z0-9_]+@.+$/, query) ->
        [_username, domain] = query |> String.trim_leading("@") |> String.split("@", parts: 2)
        domain == local_host

      true ->
        false
    end
  end

  defp already_following?(follows, remote_actor_id) do
    Enum.any?(follows, &(&1.remote_actor_id == remote_actor_id))
  end
end
