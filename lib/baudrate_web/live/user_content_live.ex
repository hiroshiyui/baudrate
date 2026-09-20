defmodule BaudrateWeb.UserContentLive do
  @moduledoc """
  LiveView for paginated lists of a user's articles or comments.

  Supports two live_actions:
  - `:articles` — paginated articles by a user
  - `:comments` — paginated comments by a user

  Redirects if the user doesn't exist or is banned.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content
  import BaudrateWeb.Helpers, only: [parse_page: 1]

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    case Auth.get_user_by_username(username) do
      nil ->
        raise BaudrateWeb.NotFoundError

      # A banned account answers exactly as one that never existed does.
      %{status: "banned"} ->
        raise BaudrateWeb.NotFoundError

      user ->
        {:ok, assign(socket, profile_user: user, syndication_user_username: user.username)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
    user = socket.assigns.profile_user
    content_type = socket.assigns.live_action

    case content_type do
      :articles ->
        result =
          Content.paginate_articles_by_user(user.id,
            page: page,
            viewer: socket.assigns[:current_user]
          )

        {:noreply,
         assign(socket,
           content_type: :articles,
           articles: result.articles,
           page: result.page,
           total_pages: result.total_pages,
           page_title: gettext("Articles by %{username}", username: user.username)
         )}

      :comments ->
        result =
          Content.paginate_comments_by_user(user.id,
            page: page,
            viewer: socket.assigns[:current_user]
          )

        {:noreply,
         assign(socket,
           content_type: :comments,
           comments: result.comments,
           page: result.page,
           total_pages: result.total_pages,
           page_title: gettext("Comments by %{username}", username: user.username)
         )}
    end
  end
end
