defmodule BaudrateWeb.UserProfileLive do
  @moduledoc """
  LiveView for public user profile pages.

  Displays a user's avatar, role, join date, content stats,
  and recent articles. Redirects if the user doesn't exist or is banned.
  Authenticated users can follow/unfollow and mute/unmute other users.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Federation
  alias BaudrateWeb.RateLimits
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

        is_following =
          if current_user && current_user.id != user.id do
            Federation.local_follows?(current_user.id, user.id)
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
           is_following: is_following,
           page_title: user.username
         )}
    end
  end

  @impl true
  def handle_event("follow_user", _params, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      case RateLimits.check_outbound_follow(current_user.id) do
        {:error, :rate_limited} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Follow rate limit exceeded. Please try again later.")
           )}

        :ok ->
          profile_user = socket.assigns.profile_user

          case Federation.create_local_follow(current_user, profile_user) do
            {:ok, _follow} ->
              {:noreply,
               socket
               |> assign(:is_following, true)
               |> put_flash(:info, gettext("Followed successfully."))}

            {:error, :self_follow} ->
              {:noreply, put_flash(socket, :error, gettext("You cannot follow yourself."))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, gettext("Already following this user."))}
          end
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unfollow_user", _params, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      profile_user = socket.assigns.profile_user

      case Federation.delete_local_follow(current_user, profile_user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:is_following, false)
           |> put_flash(:info, gettext("Unfollowed successfully."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not unfollow user."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("mute_user", _params, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      case RateLimits.check_mute_user(current_user.id) do
        {:error, :rate_limited} ->
          {:noreply,
           put_flash(socket, :error, gettext("Too many actions. Please try again later."))}

        :ok ->
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
