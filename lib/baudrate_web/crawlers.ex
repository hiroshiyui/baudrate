defmodule BaudrateWeb.Crawlers do
  @moduledoc """
  What a page tells a search engine about itself: whether to index it, and
  which URL it calls its own ([ADR 0057](../../doc/adr/0057-a-sitemap-invites-only-what-a-guest-sees.md)).

  One module, because the two answers are related — a `noindex` page gets no
  canonical, since the two directives contradict each other and a crawler is
  entitled to act on either.

  ## `noindex`, not `Disallow`

  A page blocked in `robots.txt` can still be indexed from its inbound links,
  URL and anchor text only, and its `noindex` is never read because the
  crawler never fetches it. So the pages this instance does not want in an
  index stay crawlable and say so themselves; `robots.txt` blocks only
  endpoints meant for machines (`BaudrateWeb.SitemapController`).

  Three things reach `noindex?/1`:

    * a **path** with nothing worth indexing — search results, and the pages
      of the sign-in flow;
    * an **error page**, which the root layout renders with a `:status`;
    * a page that says so itself by assigning `:noindex`, which is how an
      **unlisted article** keeps the promise its own word makes
      (`BaudrateWeb.ArticleLive`).

  Authenticated pages are deliberately absent from the list: a crawler is
  redirected to `/login` before it sees one, so a directive there would be
  decoration.

  ## Canonical

  Self-referencing per page, including `?page=N` — not collapsed onto page 1.
  `rel="prev"`/`"next"` has been ignored by Google since 2019, and a
  self-canonical is what both it and Bing act on. Every other query parameter
  is dropped, so a link decorated with tracking parameters still names the
  page it landed on.
  """

  @noindex_paths ~w(/search /login /register /password-reset /welcome /offline)
  # `/account-reset/` carries a single-use recovery token in the path itself
  # (ADR 0058). A search engine that indexed one would publish it, and a
  # referrer header would leak it — so the page refuses indexing and, because
  # `noindex_path?/1` also drives `canonical_url/2`, never names itself either.
  # `/comments/:id/history` (ADR 0060). A prefix rather than an `assign`,
  # because `noindex_path?/1` is also what suppresses the canonical, and a page
  # that says "do not index me" while naming a canonical URL contradicts
  # itself. The article's own history page is deliberately **not** here: it is
  # one page per article and has been indexable since it was written, so
  # withdrawing it is a change to existing public behaviour rather than a
  # decision about a new surface. A comment history is one page per *comment* —
  # thin, numerous, and reachable from the comment it belongs to.
  @noindex_prefixes ~w(/totp/ /account-reset/ /comments/)

  @doc """
  Returns true when this page must not be indexed.

  Takes the whole assigns map rather than a path, because two of the three
  reasons are not path-shaped. See the module note.
  """
  @spec noindex?(map()) :: boolean()
  def noindex?(assigns) do
    assigns[:noindex] == true or
      is_integer(assigns[:status]) or
      noindex_path?(assigns[:current_path])
  end

  @doc "Returns true when a path is one the site never wants indexed."
  @spec noindex_path?(String.t() | nil) :: boolean()
  def noindex_path?(path) when is_binary(path) do
    path in @noindex_paths or Enum.any?(@noindex_prefixes, &String.starts_with?(path, &1))
  end

  def noindex_path?(_), do: false

  @doc """
  Returns the absolute canonical URL for a path, or `nil` when the page is
  `noindex` (or the path is unknown).

  Only `page` survives from the query string, and only above page 1.
  """
  @spec canonical_url(String.t() | nil, map()) :: String.t() | nil
  def canonical_url(path, params \\ %{})

  def canonical_url(path, params) when is_binary(path) do
    if noindex_path?(path) do
      nil
    else
      BaudrateWeb.Endpoint.url() <> path <> page_query(params)
    end
  end

  def canonical_url(_, _), do: nil

  defp page_query(%{"page" => page}) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n > 1 -> "?page=#{n}"
      _ -> ""
    end
  end

  defp page_query(_), do: ""
end
