defmodule BaudrateWeb.FollowersLive do
  @moduledoc """
  A member's own followers, at `/followers` (ADR 0070).

  The only place a follower count or list is shown to anyone: a public count
  is a number that compares people (ADR 0056, question 2). Members of this
  instance and accounts elsewhere are listed separately, because removing
  them works differently — a local follow is simply deleted, a remote one is
  answered with `Reject(Follow)` — and neither tells the follower.

  Removing a follower does not stop them following again; blocking does, and
  the page says so. It stays open to a member under a sanction: making an
  account safer is never what a sanction takes away.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Federation
  import BaudrateWeb.Helpers, only: [parse_id: 1, translate_role: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Followers"))
     |> load()}
  end

  @impl true
  def handle_event("remove_local", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, follower_id} <- parse_id(id),
         {:ok, _} <- Federation.remove_local_follower(user, follower_id) do
      {:noreply, removed(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not remove that follower."))}
    end
  end

  def handle_event("remove_remote", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, row_id} <- parse_id(id),
         :ok <- Federation.remove_remote_follower(user, row_id) do
      {:noreply, removed(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not remove that follower."))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # The row that had focus is gone; put focus back on the page heading.
  defp removed(socket) do
    socket
    |> load()
    |> put_flash(:info, gettext("Follower removed."))
    |> push_event("focus", %{id: "followers-heading"})
  end

  defp load(socket) do
    %{local: local, remote: remote} =
      Federation.list_followers_of_user(socket.assigns.current_user)

    socket
    |> assign(:local_followers, local)
    |> assign(:remote_followers, remote)
  end
end
