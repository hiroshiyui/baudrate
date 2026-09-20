defmodule BaudrateWeb.SitemapController do
  @moduledoc """
  `robots.txt` and the sitemap documents — everything this instance says to a
  crawler before it reads a page ([ADR 0057](../../../doc/adr/0057-a-sitemap-invites-only-what-a-guest-sees.md)).

      /robots.txt            directives, and the absolute URL of the index
      /sitemap.xml           the index
      /sitemap/boards.xml    one <url> per guest-viewable board
      /sitemap/tags.xml      one per tag carried by a listed article
      /sitemap/articles-N.xml  5,000 slugs per page

  What may appear is `Baudrate.Content.Sitemap`'s decision, not this module's;
  everything here is rendering and caching.

  **`robots.txt` is a route, not a file.** The `Sitemap:` directive takes an
  absolute URL, which a file in `priv/static` cannot know for an arbitrary
  instance host. It is therefore out of `BaudrateWeb.static_paths/0`, so
  `Plug.Static` does not shadow this.

  **The child sitemaps arrive as one `:name` segment** because Phoenix cannot
  put a literal `.xml` after a path parameter. The name is matched against a
  strict regex and never reaches a file path.

  ## Caching

  A child document answers `Last-Modified` from the newest row it actually
  contains, so a poll that finds nothing new is a 304. The index gives each
  child a `<lastmod>`: exact for `boards.xml`, and for the article and tag
  pages the newest date anywhere in the inventory — an **upper** bound, so a
  crawler may refetch a child that has not changed (and get a 304) but is never
  told a changed child is current.
  """

  use BaudrateWeb, :controller

  alias Baudrate.Content
  alias BaudrateWeb.HTTPCaching
  alias BaudrateWeb.SitemapXML

  @urls_per_sitemap 5_000

  @simple_child ~r/\A(boards|tags)\.xml\z/
  @article_child ~r/\Aarticles-(\d{1,6})\.xml\z/

  @doc "Renders the sitemap index listing every child document that exists."
  def index(conn, _params) do
    boards = Content.sitemap_public_boards()
    tags = Content.sitemap_public_tags()
    article_count = Content.count_sitemap_public_articles()

    boards_lastmod = newest(Enum.map(boards, &elem(&1, 1)))
    inventory_lastmod = newest([boards_lastmod, Content.sitemap_newest_article_date()])

    children =
      [{boards != [], "/sitemap/boards.xml", boards_lastmod}] ++
        [{tags != [], "/sitemap/tags.xml", inventory_lastmod}] ++
        for page <- 1..article_pages(article_count)//1 do
          {true, "/sitemap/articles-#{page}.xml", inventory_lastmod}
        end

    sitemaps =
      for {include?, path, lastmod} <- children, include?, do: {SitemapXML.url(path), lastmod}

    render_xml(conn, :sitemapindex, %{sitemaps: sitemaps}, inventory_lastmod)
  end

  @doc "Renders one child sitemap, or 404 for a name or page that does not exist."
  def child(conn, %{"name" => name}) do
    cond do
      Regex.match?(@simple_child, name) -> render_simple_child(conn, name)
      match = Regex.run(@article_child, name) -> render_article_child(conn, match)
      true -> send_resp(conn, 404, "Not Found")
    end
  end

  @doc """
  Renders `robots.txt`.

  Only machine endpoints are disallowed. The pages this instance does not want
  indexed — search, login, registration, password reset — stay crawlable and
  carry `noindex` instead (`BaudrateWeb.Crawlers`): a blocked page can still be
  indexed from its inbound links, URL only, and its `noindex` is never read
  because the crawler never fetches it. Blocking is not the directive that
  removes a page from an index.
  """
  # sobelow_skip ["XSS.SendResp"]
  def robots(conn, _params) do
    body = """
    User-agent: *
    Disallow: /ap/
    Disallow: /api/
    Disallow: /exports/

    Sitemap: #{SitemapXML.url("/sitemap.xml")}
    """

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, body)
  end

  # --- Children ---

  defp render_simple_child(conn, "boards.xml") do
    urls =
      for {slug, lastmod} <- Content.sitemap_public_boards(),
          do: {loc("/boards/#{slug}"), lastmod}

    render_urlset(conn, urls)
  end

  defp render_simple_child(conn, "tags.xml") do
    # A tag page has no date of its own — it is a query over articles that each
    # carry theirs — so no <lastmod> is claimed for one.
    urls = for tag <- Content.sitemap_public_tags(), do: {loc("/tags/#{tag}"), nil}

    render_urlset(conn, urls)
  end

  defp render_article_child(conn, [_, page_string]) do
    page = String.to_integer(page_string)
    count = Content.count_sitemap_public_articles()

    if page < 1 or page > article_pages(count) do
      send_resp(conn, 404, "Not Found")
    else
      offset = (page - 1) * @urls_per_sitemap

      urls =
        for {slug, lastmod} <- Content.sitemap_public_article_slugs(offset, @urls_per_sitemap),
            do: {loc("/articles/#{slug}"), lastmod}

      render_urlset(conn, urls)
    end
  end

  # --- Helpers ---

  defp loc(path), do: SitemapXML.url(path)

  defp render_urlset(conn, urls) do
    render_xml(conn, :urlset, %{urls: urls}, newest(Enum.map(urls, &elem(&1, 1))))
  end

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp render_xml(conn, template, assigns, last_modified) do
    if HTTPCaching.not_modified_since?(conn, last_modified) do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type("application/xml")
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> HTTPCaching.put_last_modified(last_modified)
      |> send_resp(200, SitemapXML.render(template, assigns))
    end
  end

  defp article_pages(0), do: 0
  defp article_pages(count), do: div(count - 1, @urls_per_sitemap) + 1

  defp newest(dates) do
    dates
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end
end
