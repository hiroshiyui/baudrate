defmodule BaudrateWeb.PageController do
  @moduledoc """
  Controller for static pages (home page).
  """

  use BaudrateWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  @doc """
  The page the service worker serves when a navigation cannot reach us.

  It is a route rather than a file in `priv/static` so it is translated and
  themed like every other page — the worker re-fetches it after each
  successful navigation, so the cached copy follows the reader's language
  instead of freezing whichever one was active when the worker installed.

  `noindex` is assigned directly rather than by path: `Crawlers.noindex?/1`
  reads `:current_path` from assigns, which `AuthHooks` sets for LiveViews
  and nothing sets for a controller. It is listed in `@noindex_paths` as well,
  so the two agree however the page is reached.

  It needs nothing from the network to render: the Cache API stores a response
  with its headers, so the cached copy carries its own CSP — including the
  hash of the theme bootstrap inlined in that same copy, which is why the two
  stay consistent however old the copy gets. What can go stale is the theme
  and the language, and the worker's refresh after each successful navigation
  is what keeps those current.
  """
  def offline(conn, _params) do
    conn
    |> assign(:noindex, true)
    |> assign(:page_title, gettext("You are offline"))
    |> render(:offline)
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
