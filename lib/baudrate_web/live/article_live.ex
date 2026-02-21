defmodule BaudrateWeb.ArticleLive do
  @moduledoc """
  LiveView for displaying a single article.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Guests can only view articles that belong to at least one public board;
  articles exclusively in private boards redirect to `/login`.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    article = Content.get_article_by_slug!(slug)
    current_user = socket.assigns.current_user

    if is_nil(current_user) and not has_public_board?(article) do
      {:ok, redirect(socket, to: "/login")}
    else
      {:ok, assign(socket, :article, article)}
    end
  end

  defp has_public_board?(article) do
    Enum.any?(article.boards, &(&1.visibility == "public"))
  end
end
