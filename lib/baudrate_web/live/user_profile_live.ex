defmodule BaudrateWeb.UserProfileLive do
  @moduledoc """
  LiveView for public user profile pages.

  Displays a user's avatar, role, join date, content stats,
  and recent articles. Redirects if the user doesn't exist or is banned.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content
  import BaudrateWeb.Helpers, only: [translate_role: 1]

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    case Auth.get_user_by_username(username) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("User not found."))
         |> redirect(to: ~p"/")}

      %{status: "banned"} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("User not found."))
         |> redirect(to: ~p"/")}

      user ->
        recent_articles = Content.list_recent_articles_by_user(user.id)
        article_count = Content.count_articles_by_user(user.id)
        comment_count = Content.count_comments_by_user(user.id)
        current_user = socket.assigns.current_user

        is_muted =
          if current_user && current_user.id != user.id do
            Auth.muted?(current_user, user)
          else
            false
          end

        {:ok,
         assign(socket,
           profile_user: user,
           recent_articles: recent_articles,
           article_count: article_count,
           comment_count: comment_count,
           is_muted: is_muted,
           page_title: user.username
         )}
    end
  end

  @impl true
  def handle_event("mute_user", _params, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      profile_user = socket.assigns.profile_user

      case Auth.mute_user(current_user, profile_user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:is_muted, true)
           |> put_flash(:info, gettext("User muted."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to mute user."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unmute_user", _params, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      profile_user = socket.assigns.profile_user

      Auth.unmute_user(current_user, profile_user)

      {:noreply,
       socket
       |> assign(:is_muted, false)
       |> put_flash(:info, gettext("User unmuted."))}
    else
      {:noreply, socket}
    end
  end

end
