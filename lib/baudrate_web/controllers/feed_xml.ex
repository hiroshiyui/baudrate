defmodule BaudrateWeb.FeedXML do
  @moduledoc """
  Renders RSS 2.0 and Atom 1.0 XML feeds from article data.

  Uses compile-time EEx templates for efficiency. Provides helper functions
  for XML escaping, date formatting (RFC 822 for RSS, RFC 3339 for Atom),
  and article URL/content generation.
  """

  require EEx

  @template_dir Path.join(__DIR__, "feed_xml")

  EEx.function_from_file(:def, :render_rss, Path.join(@template_dir, "rss.xml.eex"), [:assigns])
  EEx.function_from_file(:def, :render_atom, Path.join(@template_dir, "atom.xml.eex"), [:assigns])

  @doc """
  Renders a feed in the given format (`:rss` or `:atom`).
  """
  def render(:rss, assigns), do: render_rss(assigns)
  def render(:atom, assigns), do: render_atom(assigns)

  @doc """
  Escapes a string for safe inclusion in XML text nodes and attributes.
  """
  def xml_escape(nil), do: ""

  def xml_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  @doc """
  Returns the display name for an article's author.
  """
  def author_name(%{user: %{username: username}}) when is_binary(username), do: username
  def author_name(_), do: "Unknown"

  @doc """
  Returns the full URL for an article.
  """
  def article_url(article) do
    BaudrateWeb.Endpoint.url() <> "/articles/#{article.slug}"
  end

  @doc """
  Returns the article body rendered as sanitized HTML for feed content.
  """
  def article_html(article) do
    Baudrate.Content.Markdown.to_html(article.body)
  end

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  Formats a `DateTime` as RFC 822 (used in RSS 2.0 `<pubDate>`).

  Example: `"Sun, 23 Feb 2026 05:57:22 +0000"`
  """
  def rfc822(%DateTime{} = dt) do
    day_name = Enum.at(@days, Date.day_of_week(dt) - 1)
    month_name = Enum.at(@months, dt.month - 1)

    "#{day_name}, #{pad2(dt.day)} #{month_name} #{dt.year} #{pad2(dt.hour)}:#{pad2(dt.minute)}:#{pad2(dt.second)} +0000"
  end

  @doc """
  Formats a `DateTime` as RFC 3339 (used in Atom 1.0 `<updated>`/`<published>`).

  Example: `"2026-02-23T05:57:22Z"`
  """
  def rfc3339(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"
end
