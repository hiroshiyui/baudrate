defmodule BaudrateWeb.SitemapXML do
  @moduledoc """
  Renders the sitemap index and `urlset` documents from compile-time EEx
  templates, the same way `BaudrateWeb.SyndicationFeedXML` renders the feeds —
  both are fixed XML formats with no need for a library.

  Both templates take `[{loc, lastmod}]`, where `lastmod` may be `nil` and the
  element is then omitted rather than written empty.

  **A path is percent-encoded before it is XML-escaped, in that order.** Board
  slugs are ASCII, but a tag is `\\A\\p{L}[\\w]{0,63}\\z` — any Unicode letter —
  so `/tags/台灣` is not a URL until `URI.encode/1` has run, and escaping first
  would then encode the escapes.
  """

  require EEx

  alias BaudrateWeb.XML

  @template_dir Path.join(__DIR__, "sitemap_xml")

  EEx.function_from_file(
    :def,
    :render_sitemapindex,
    Path.join(@template_dir, "sitemapindex.xml.eex"),
    [:assigns]
  )

  EEx.function_from_file(:def, :render_urlset, Path.join(@template_dir, "urlset.xml.eex"), [
    :assigns
  ])

  @doc "Renders `:sitemapindex` or `:urlset`."
  @spec render(:sitemapindex | :urlset, map()) :: String.t()
  def render(:sitemapindex, assigns), do: render_sitemapindex(assigns)
  def render(:urlset, assigns), do: render_urlset(assigns)

  @doc "Escapes a string for an XML text node."
  defdelegate xml_escape(text), to: XML, as: :escape

  @doc """
  Builds an absolute URL for a site-relative path, percent-encoding the path
  segments that are not already safe.
  """
  @spec url(String.t()) :: String.t()
  def url(path) when is_binary(path) do
    BaudrateWeb.Endpoint.url() <> URI.encode(path)
  end

  @doc """
  Formats a timestamp as the W3C Datetime the sitemap schema asks for
  (RFC 3339 in UTC).
  """
  @spec w3c_datetime(DateTime.t() | NaiveDateTime.t()) :: String.t()
  def w3c_datetime(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
  end

  def w3c_datetime(%NaiveDateTime{} = dt) do
    dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
