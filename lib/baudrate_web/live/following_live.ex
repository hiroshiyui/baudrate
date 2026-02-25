defmodule BaudrateWeb.FollowingLive do
  @moduledoc """
  LiveView for managing outbound follows to remote ActivityPub actors
  and local users.

  Authenticated users can view their followed actors/users with state badges
  (pending/accepted/rejected) and unfollow them. Accessible at `/following`
  within the `:authenticated` live_session.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Federation
  alias Baudrate.Federation.{Delivery, Publisher}
  import BaudrateWeb.Helpers, only: [parse_id: 1, translate_role: 1]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    follows = Federation.list_user_follows(user.id)

    {:ok,
     socket
     |> assign(:follows, follows)
     |> assign(:page_title, gettext("Following"))}
  end

  @impl true
  def handle_event("unfollow", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, remote_actor_id} <- parse_id(id),
         remote_actor when not is_nil(remote_actor) <-
           Baudrate.Repo.get(Federation.RemoteActor, remote_actor_id),
         follow when not is_nil(follow) <-
           Federation.get_user_follow(user.id, remote_actor_id) do
      follow = Baudrate.Repo.preload(follow, :remote_actor)
      {activity, actor_uri} = Publisher.build_undo_follow(user, follow)
      Delivery.deliver_follow(activity, remote_actor, actor_uri)
      Federation.delete_user_follow(user, remote_actor)

      follows = Federation.list_user_follows(user.id)

      {:noreply,
       socket
       |> assign(:follows, follows)
       |> put_flash(:info, gettext("Unfollowed successfully."))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not unfollow actor."))}
    end
  end

  @impl true
  def handle_event("unfollow_user", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, followed_user_id} <- parse_id(id),
         followed_user when not is_nil(followed_user) <-
           Auth.get_user(followed_user_id),
         {:ok, _follow} <- Federation.delete_local_follow(user, followed_user) do
      follows = Federation.list_user_follows(user.id)

      {:noreply,
       socket
       |> assign(:follows, follows)
       |> put_flash(:info, gettext("Unfollowed successfully."))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not unfollow user."))}
    end
  end
end
