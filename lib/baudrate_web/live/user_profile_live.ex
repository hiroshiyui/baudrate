defmodule BaudrateWeb.UserProfileLive do
  @moduledoc """
  LiveView for public user profile pages.

  Displays a user's avatar, role, join date, content stats,
  and recent articles. Redirects if the user doesn't exist or is banned.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content

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

        {:ok,
         assign(socket,
           profile_user: user,
           recent_articles: recent_articles,
           article_count: article_count,
           comment_count: comment_count,
           page_title: user.username
         )}
    end
  end

  defp translate_role("admin"), do: gettext("admin")
  defp translate_role("moderator"), do: gettext("moderator")
  defp translate_role("user"), do: gettext("user")
  defp translate_role("guest"), do: gettext("guest")
  defp translate_role(other), do: other
end
