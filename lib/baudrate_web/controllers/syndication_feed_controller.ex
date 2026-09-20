defmodule BaudrateWeb.SyndicationFeedController do
  @moduledoc """
  Controller for RSS 2.0 and Atom 1.0 syndication feeds.

  Provides feeds at three scopes:

    * **Site-wide** — all public boards (`/feeds/rss`, `/feeds/atom`)
    * **Per-board** — single public board (`/feeds/boards/:slug/rss`, `/feeds/boards/:slug/atom`)
    * **Per-user** — user's articles in public boards (`/feeds/users/:username/rss`, `/feeds/users/:username/atom`)
    * **Per-tag** — articles carrying a hashtag (`/feeds/tags/:tag/rss`, `/feeds/tags/:tag/atom`)

  Only local articles are included (no remote/federated articles). Feeds include
  `Cache-Control` and `Last-Modified` headers, with `If-Modified-Since` → 304
  support for efficient polling by feed readers.
  """

  use BaudrateWeb, :controller

  alias Baudrate.{Auth, Content}
  alias BaudrateWeb.HTTPCaching
  alias BaudrateWeb.SyndicationFeedXML

  @slug_re ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @username_re ~r/\A[a-zA-Z0-9_]+\z/
  # The same pattern `BaudrateWeb.TagLive` accepts, so a feed exists for
  # exactly the tag pages that do.
  @tag_re ~r/\A\p{L}[\w]{0,63}\z/u

  # --- Site-wide feeds ---

  @doc "Renders the site-wide RSS 2.0 feed of recent public articles."
  def site_rss(conn, _params) do
    articles = Content.list_recent_public_articles()
    site_name = Baudrate.Setup.get_setting("site_name") || "Baudrate"
    base = BaudrateWeb.Endpoint.url()

    render_feed(conn, :rss, articles, %{
      title: site_name,
      link: base <> "/",
      description: gettext("Recent articles on %{site_name}", site_name: site_name),
      self_url: base <> "/feeds/rss"
    })
  end

  @doc "Renders the site-wide Atom 1.0 feed of recent public articles."
  def site_atom(conn, _params) do
    articles = Content.list_recent_public_articles()
    site_name = Baudrate.Setup.get_setting("site_name") || "Baudrate"
    base = BaudrateWeb.Endpoint.url()

    render_feed(conn, :atom, articles, %{
      title: site_name,
      link: base <> "/",
      self_url: base <> "/feeds/atom"
    })
  end

  # --- Board feeds ---

  @doc "Renders the RSS 2.0 feed for a single public board."
  def board_rss(conn, %{"slug" => slug}) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- get_public_board(slug),
         {:ok, articles} <- Content.list_recent_articles_for_public_board(board) do
      base = BaudrateWeb.Endpoint.url()

      render_feed(conn, :rss, articles, %{
        title: board.name,
        link: base <> "/boards/#{board.slug}",
        description:
          board.description || gettext("Articles in %{board_name}", board_name: board.name),
        self_url: base <> "/feeds/boards/#{board.slug}/rss"
      })
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  @doc "Renders the Atom 1.0 feed for a single public board."
  def board_atom(conn, %{"slug" => slug}) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- get_public_board(slug),
         {:ok, articles} <- Content.list_recent_articles_for_public_board(board) do
      base = BaudrateWeb.Endpoint.url()

      render_feed(conn, :atom, articles, %{
        title: board.name,
        link: base <> "/boards/#{board.slug}",
        self_url: base <> "/feeds/boards/#{board.slug}/atom"
      })
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  # --- User feeds ---

  @doc "Renders the RSS 2.0 feed of a user's articles in public boards."
  def user_rss(conn, %{"username" => username}) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <- Auth.get_user_by_username(username),
         false <- user.status == "banned" do
      articles = Content.list_recent_public_articles_by_user(user.id)
      base = BaudrateWeb.Endpoint.url()

      render_feed(conn, :rss, articles, %{
        title: gettext("%{username}'s articles", username: user.username),
        link: base <> "/users/#{user.username}",
        description: gettext("Recent articles by %{username}", username: user.username),
        self_url: base <> "/feeds/users/#{user.username}/rss"
      })
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  @doc "Renders the Atom 1.0 feed of a user's articles in public boards."
  def user_atom(conn, %{"username" => username}) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <- Auth.get_user_by_username(username),
         false <- user.status == "banned" do
      articles = Content.list_recent_public_articles_by_user(user.id)
      base = BaudrateWeb.Endpoint.url()

      render_feed(conn, :atom, articles, %{
        title: gettext("%{username}'s articles", username: user.username),
        link: base <> "/users/#{user.username}",
        self_url: base <> "/feeds/users/#{user.username}/atom"
      })
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  # --- Tag feeds ---

  @doc "Renders the RSS 2.0 feed of local public articles carrying a tag."
  def tag_rss(conn, %{"tag" => tag}), do: render_tag_feed(conn, :rss, tag)

  @doc "Renders the Atom 1.0 feed of local public articles carrying a tag."
  def tag_atom(conn, %{"tag" => tag}), do: render_tag_feed(conn, :atom, tag)

  defp render_tag_feed(conn, format, raw_tag) do
    tag = String.downcase(raw_tag)

    if Regex.match?(@tag_re, tag) do
      articles = Content.list_recent_public_articles_by_tag(tag)
      base = BaudrateWeb.Endpoint.url()
      suffix = if format == :rss, do: "rss", else: "atom"

      render_feed(conn, format, articles, %{
        title: gettext("Articles tagged #%{tag}", tag: tag),
        link: base <> "/tags/" <> URI.encode(tag),
        description: gettext("Recent articles tagged #%{tag}", tag: tag),
        self_url: base <> "/feeds/tags/" <> URI.encode(tag) <> "/" <> suffix
      })
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  # --- Helpers ---

  defp get_public_board(slug) do
    case Baudrate.Repo.get_by(Content.Board, slug: slug) do
      %{min_role_to_view: "guest"} = board -> board
      _ -> nil
    end
  end

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp render_feed(conn, format, articles, meta) do
    last_modified = newest_date(articles)

    if HTTPCaching.not_modified_since?(conn, last_modified) do
      send_resp(conn, 304, "")
    else
      content_type =
        case format do
          :rss -> "application/rss+xml"
          :atom -> "application/atom+xml"
        end

      assigns =
        Map.merge(meta, %{
          articles: articles,
          language: Gettext.get_locale(BaudrateWeb.Gettext),
          last_build_date: last_modified,
          updated: last_modified
        })

      xml = SyndicationFeedXML.render(format, assigns)

      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("cache-control", "public, max-age=300")
      |> HTTPCaching.put_last_modified(last_modified)
      |> send_resp(200, xml)
    end
  end

  defp newest_date([article | _]), do: article.inserted_at
  defp newest_date([]), do: nil
end
