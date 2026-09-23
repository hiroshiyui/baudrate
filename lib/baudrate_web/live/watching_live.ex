defmodule BaudrateWeb.WatchingLive do
  @moduledoc """
  The boards and threads a member watches, at `/watching` (ADR 0070).

  Every row here was created by the member's own "Watch" toggle — nothing
  else creates one — and each can be removed from here as well as from the
  board or thread itself.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Watching"))
     |> load()}
  end

  @impl true
  def handle_event("unwatch", %{"id" => id}, socket) do
    with {:ok, watch_id} <- parse_id(id),
         {:ok, :removed} <- Content.delete_watch(socket.assigns.current_user, watch_id) do
      {:noreply,
       socket
       |> load()
       |> put_flash(:info, gettext("No longer watching."))
       |> push_event("focus", %{id: "watching-heading"})}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not stop watching that."))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # A board or thread the member can no longer open keeps its row, so it can
  # still be removed, but is not named: its title is no longer theirs to read.
  defp load(socket) do
    user = socket.assigns.current_user
    watches = Content.list_watches(user)

    socket
    |> assign(
      :board_watches,
      for(w <- watches, w.board_id, do: {w, Content.can_view_board?(w.board, user)})
    )
    |> assign(
      :article_watches,
      for(
        w <- watches,
        w.article_id,
        do: {w, Baudrate.Content.Interactions.article_visible_to_user?(w.article_id, user.id)}
      )
    )
  end
end
