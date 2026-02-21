defmodule BaudrateWeb.ArticleLive do
  @moduledoc """
  LiveView for displaying a single article.

  Loads the article by slug with boards and user preloaded.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    article = Content.get_article_by_slug!(slug)
    {:ok, assign(socket, :article, article)}
  end
end
