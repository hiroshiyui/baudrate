defmodule Baudrate.Bots.FaviconFetcher do
  @moduledoc """
  Fetches a site's favicon and sets it as the bot user's avatar.

  Scans the site's HTML for `<link rel="apple-touch-icon">` and
  `<link rel="icon">` tags, picks the best raster image (SVG links are
  skipped), downloads the image, and processes it through the avatar
  pipeline (magic bytes validation, libvips re-encode to WebP, EXIF strip).

  When no raster icon succeeds, well-known standard paths
  (`/apple-touch-icon.png`, `/favicon.ico`) are tried in order.

  Each candidate is tried end-to-end (download + process): if download
  succeeds but the image format is unsupported (e.g. ICO when only SVG
  and ICO are advertised in HTML), the next candidate is attempted.

  All operations are best-effort — failures are logged but never
  propagate to callers.
  """

  require Logger

  alias Baudrate.Avatar
  alias Baudrate.Auth
  alias Baudrate.Bots
  alias Baudrate.Federation.HTTPClient

  @max_favicon_size 2 * 1024 * 1024

  @doc """
  Fetches the favicon for the bot's feed URL and sets it as the bot user's avatar.

  Returns `:ok` on success or `:ok` on any failure (best-effort).
  """
  @spec fetch_and_set(Baudrate.Bots.Bot.t()) :: :ok
  def fetch_and_set(bot) do
    bot = Baudrate.Repo.preload(bot, :user)

    case try_favicon_candidates(bot.feed_url) do
      {:ok, favicon_url, avatar_id} ->
        old_avatar_id = bot.user.avatar_id

        case Auth.update_avatar(bot.user, avatar_id) do
          {:ok, _} ->
            Avatar.delete_avatar(old_avatar_id)
            Bots.mark_avatar_refreshed(bot)

            Logger.info(
              "bots.favicon_fetcher: set avatar for bot #{bot.id} from #{favicon_url}"
            )

          {:error, reason} ->
            Avatar.delete_avatar(avatar_id)

            Logger.warning(
              "bots.favicon_fetcher: failed to update avatar for bot #{bot.id}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.info(
          "bots.favicon_fetcher: skipping favicon for bot #{bot.id}: #{inspect(reason)}"
        )
    end

    :ok
  end

  # Tries each candidate URL in priority order, returning the first that
  # both downloads successfully AND can be processed through the avatar
  # pipeline (JPEG/PNG/WebP). Moves to the next candidate on any failure.
  defp try_favicon_candidates(feed_url) do
    site_url = extract_site_url(feed_url)
    candidates = build_favicon_candidates(site_url)

    Enum.reduce_while(candidates, {:error, :no_usable_favicon}, fn url, _acc ->
      with {:ok, data} <- download_favicon(url, site_url),
           {:ok, avatar_id} <- process_favicon(data) do
        {:halt, {:ok, url, avatar_id}}
      else
        {:error, _} -> {:cont, {:error, :no_usable_favicon}}
      end
    end)
  end

  # Returns a deduplicated, ordered list of candidate URLs:
  # 1. Raster icon URLs from HTML <link> tags (apple-touch-icon first, SVG excluded)
  # 2. Standard well-known paths
  defp build_favicon_candidates(site_url) do
    html_candidates =
      case HTTPClient.get_html(site_url) do
        {:ok, %{body: body}} -> extract_raster_icon_urls(body, site_url)
        {:error, _} -> []
      end

    standard_paths = [
      site_url <> "/apple-touch-icon.png",
      site_url <> "/apple-touch-icon-precomposed.png",
      site_url <> "/favicon.ico"
    ]

    (html_candidates ++ standard_paths) |> Enum.uniq()
  end

  # Extracts raster icon URLs from HTML link tags, skipping SVG.
  # Priority: apple-touch-icon (largest first) > icon/shortcut icon (largest first).
  defp extract_raster_icon_urls(html, site_url) do
    links =
      html
      |> extract_link_tags()
      |> Enum.reject(&svg_link?/1)

    apple =
      links
      |> Enum.filter(fn l -> l.rel in ["apple-touch-icon", "apple-touch-icon-precomposed"] end)
      |> Enum.sort_by(&parse_icon_size/1, :desc)

    icon =
      links
      |> Enum.filter(fn l -> l.rel in ["icon", "shortcut icon"] end)
      |> Enum.sort_by(&parse_icon_size/1, :desc)

    (apple ++ icon)
    |> Enum.map(fn l -> resolve_url(l.href, site_url) end)
  end

  defp svg_link?(%{type: type, href: href}) do
    svg_type = is_binary(type) and String.contains?(type, "svg")

    svg_href =
      is_binary(href) and
        href
        |> URI.parse()
        |> Map.get(:path, "")
        |> then(&(is_binary(&1) and String.ends_with?(String.downcase(&1), ".svg")))

    svg_type or svg_href
  end

  defp extract_site_url(feed_url) do
    uri = URI.parse(feed_url)
    %URI{scheme: uri.scheme, host: uri.host, port: uri.port} |> URI.to_string()
  end

  defp extract_link_tags(html) do
    ~r/<link\s+([^>]+)>/i
    |> Regex.scan(html)
    |> Enum.map(fn [_, attrs] ->
      %{
        rel: extract_attr(attrs, "rel") || "",
        href: extract_attr(attrs, "href") || "",
        sizes: extract_attr(attrs, "sizes") || "",
        type: extract_attr(attrs, "type") || ""
      }
    end)
    |> Enum.filter(fn l -> l.href != "" end)
  end

  defp extract_attr(attrs, name) do
    case Regex.run(~r/#{name}=["']([^"']+)["']/i, attrs) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp parse_icon_size(%{sizes: sizes}) do
    case Regex.run(~r/(\d+)x\d+/i, sizes) do
      [_, n] ->
        case Integer.parse(n) do
          {size, ""} -> size
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp resolve_url(href, site_url) when is_binary(href) do
    case URI.parse(href) do
      %URI{scheme: nil} ->
        URI.merge(URI.parse(site_url), href) |> URI.to_string()

      _ ->
        href
    end
  end

  defp download_favicon(url, referer) do
    case HTTPClient.get_html(url,
           max_size: @max_favicon_size,
           headers: [{"referer", referer}]
         ) do
      {:ok, %{body: body}} when byte_size(body) > 0 ->
        {:ok, body}

      {:ok, _} ->
        {:error, :empty_response}

      {:error, _} = err ->
        err
    end
  end

  defp process_favicon(image_data) do
    tmp_path =
      System.tmp_dir!() |> Path.join("favicon_#{:erlang.unique_integer([:positive])}")

    try do
      File.write!(tmp_path, image_data)
      Avatar.process_upload(tmp_path, nil)
    after
      File.rm(tmp_path)
    end
  end
end
