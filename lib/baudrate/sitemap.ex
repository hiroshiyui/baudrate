defmodule Baudrate.Sitemap do
  @moduledoc """
  Generates a sitemap.xml file for search engine indexing.

  Includes all publicly accessible content:
    * Homepage
    * Public boards (guest-visible)
    * Public articles (in guest-visible boards, not soft-deleted)

  User profiles are intentionally excluded for privacy.

  The generated file is written to `priv/static/sitemap.xml` and served
  directly by Nginx as a static file.
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Content.{Article, Board, BoardArticle}

  @doc """
  Generates the sitemap XML and writes it to `priv/static/sitemap.xml`.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec generate() :: :ok | {:error, term()}
  def generate do
    xml = build_xml()
    path = output_path()

    case File.write(path, xml) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds the sitemap XML string.
  """
  @spec build_xml() :: String.t()
  def build_xml do
    base = BaudrateWeb.Endpoint.url()

    urls =
      [homepage_entry(base)] ++
        board_entries(base) ++
        article_entries(base)

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n),
      urls,
      ~s(</urlset>\n)
    ]
    |> IO.iodata_to_binary()
  end

  defp homepage_entry(base) do
    url_element(base <> "/", nil, "daily", "1.0")
  end

  defp board_entries(base) do
    from(b in Board,
      where: b.min_role_to_view == "guest",
      order_by: [asc: b.position, asc: b.id],
      select: {b.slug, b.updated_at}
    )
    |> Repo.all()
    |> Enum.map(fn {slug, updated_at} ->
      url_element("#{base}/boards/#{slug}", updated_at, "daily", "0.8")
    end)
  end

  defp article_entries(base) do
    from(a in Article,
      join: ba in BoardArticle,
      on: ba.article_id == a.id,
      join: b in Board,
      on: b.id == ba.board_id,
      where:
        is_nil(a.deleted_at) and
          not is_nil(a.user_id) and
          b.min_role_to_view == "guest",
      distinct: a.id,
      order_by: [desc: a.inserted_at, desc: a.id],
      select: {a.slug, a.updated_at}
    )
    |> Repo.all()
    |> Enum.map(fn {slug, updated_at} ->
      url_element("#{base}/articles/#{slug}", updated_at, "weekly", "0.6")
    end)
  end

  defp url_element(loc, lastmod, changefreq, priority) do
    lastmod_tag =
      if lastmod do
        date = lastmod |> DateTime.to_date() |> Date.to_iso8601()
        "  <lastmod>#{date}</lastmod>\n"
      else
        ""
      end

    [
      "  <url>\n",
      "    <loc>#{xml_escape(loc)}</loc>\n",
      lastmod_tag,
      "    <changefreq>#{changefreq}</changefreq>\n",
      "    <priority>#{priority}</priority>\n",
      "  </url>\n"
    ]
  end

  defp xml_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp output_path do
    Application.app_dir(:baudrate, Path.join(["priv", "static", "sitemap.xml"]))
  end
end
