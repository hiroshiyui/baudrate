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
    # `~p` encodes what it interpolates, so hand it the params themselves: a
    # string pre-encoded with `URI.encode_query/1` comes back escaped again as
    # one opaque value, turning `?page=3` into `?page%3D3`.
    #
    # An allow-list, not `Map.drop/2`: `~p` ultimately calls
    # `Plug.Conn.Query.encode/2`, which *raises* on "maps inside lists when
    # the map has 0 or more than 1 element" — a shape a query string can
    # decode to. `GET /feed?a[][b]=1&a[][c]=2` therefore crashed the
    # controller, and this route sits in the plain `:browser` pipeline with no
    # per-IP limit, so it was an unauthenticated, repeatable 500. Only `page`
    # has ever meant anything here.
    params =
      params
      |> Map.take(["page"])
      |> Map.filter(fn {_k, v} -> is_binary(v) end)

    target = if params == %{}, do: ~p"/timeline", else: ~p"/timeline?#{params}"

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: target)
  end
end
