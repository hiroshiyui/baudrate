defmodule BaudrateWeb.FeedController do
  @moduledoc """
  Controller for RSS 2.0 and Atom 1.0 syndication feeds.

  Provides feeds at three scopes:

    * **Site-wide** — all public boards (`/feeds/rss`, `/feeds/atom`)
    * **Per-board** — single public board (`/feeds/boards/:slug/rss`, `/feeds/boards/:slug/atom`)
    * **Per-user** — user's articles in public boards (`/feeds/users/:username/rss`, `/feeds/users/:username/atom`)

  Only local articles are included (no remote/federated articles). Feeds include
  `Cache-Control` and `Last-Modified` headers, with `If-Modified-Since` → 304
  support for efficient polling by feed readers.
  """

  use BaudrateWeb, :controller

  alias Baudrate.{Auth, Content}
  alias BaudrateWeb.FeedXML

  @slug_re ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @username_re ~r/\A[a-zA-Z0-9_]+\z/

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
        description: board.description || gettext("Articles in %{board_name}", board_name: board.name),
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

  # --- Helpers ---

  defp get_public_board(slug) do
    case Baudrate.Repo.get_by(Content.Board, slug: slug) do
      %{min_role_to_view: "guest"} = board -> board
      _ -> nil
    end
  end

  defp render_feed(conn, format, articles, meta) do
    last_modified = newest_date(articles)

    if not_modified_since?(conn, last_modified) do
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

      xml = FeedXML.render(format, assigns)

      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("cache-control", "public, max-age=300")
      |> maybe_put_last_modified(last_modified)
      |> send_resp(200, xml)
    end
  end

  defp newest_date([article | _]), do: article.inserted_at
  defp newest_date([]), do: nil

  defp maybe_put_last_modified(conn, nil), do: conn

  defp maybe_put_last_modified(conn, dt) do
    put_resp_header(conn, "last-modified", format_http_date(dt))
  end

  defp not_modified_since?(_conn, nil), do: false

  defp not_modified_since?(conn, last_modified) do
    case get_req_header(conn, "if-modified-since") do
      [ims_string] ->
        case parse_http_date(ims_string) do
          {:ok, ims_dt} ->
            DateTime.compare(last_modified, ims_dt) in [:lt, :eq]

          _ ->
            false
        end

      _ ->
        false
    end
  end

  @http_days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @http_months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp format_http_date(%DateTime{} = dt) do
    day_name = Enum.at(@http_days, Date.day_of_week(dt) - 1)
    month_name = Enum.at(@http_months, dt.month - 1)

    "#{day_name}, #{pad2(dt.day)} #{month_name} #{dt.year} #{pad2(dt.hour)}:#{pad2(dt.minute)}:#{pad2(dt.second)} GMT"
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  @month_map %{
    "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4,
    "May" => 5, "Jun" => 6, "Jul" => 7, "Aug" => 8,
    "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12
  }

  defp parse_http_date(string) do
    # Parse RFC 7231 / IMF-fixdate: "Sun, 23 Feb 2026 05:57:22 GMT"
    case Regex.run(
           ~r/\w+, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT/,
           string
         ) do
      [_, day, month_str, year, hour, min, sec] ->
        with month when is_integer(month) <- Map.get(@month_map, month_str) do
          DateTime.new(
            Date.new!(String.to_integer(year), month, String.to_integer(day)),
            Time.new!(String.to_integer(hour), String.to_integer(min), String.to_integer(sec))
          )
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
