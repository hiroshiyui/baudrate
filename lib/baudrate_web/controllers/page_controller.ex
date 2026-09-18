defmodule BaudrateWeb.PageController do
  @moduledoc """
  Controller for static pages (home page).
  """

  use BaudrateWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  @doc """
  Redirects `/feed` to `/timeline`, where the personal stream now lives.

  The page was `/feed` until the vocabulary was settled: "feed" also names the
  RSS and Atom the bots read and the syndication we publish, so the stream
  everyone else calls a timeline is called one here too. Members bookmark this
  page, so the old path keeps working; 301 rather than 302 so a browser stops
  asking. The query string carries over, because the pager puts `?page` here.
  """
  def feed_redirect(conn, params) do
    query = Map.drop(params, ~w(controller action)) |> URI.encode_query()
    target = if query == "", do: ~p"/timeline", else: ~p"/timeline?#{query}"

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: target)
  end
end
