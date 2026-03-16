defmodule Baudrate.Bots.FaviconFetcher do
  @moduledoc """
  Fetches a site's favicon and sets it as the bot user's avatar.

  Scans the site's HTML for `<link rel="apple-touch-icon">` and
  `<link rel="icon">` tags, picks the best one, downloads the image,
  and processes it through the avatar pipeline (magic bytes validation,
  libvips re-encode to WebP, EXIF strip).

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

    with {:ok, favicon_url} <- find_favicon_url(bot.feed_url),
         {:ok, image_data} <- download_favicon(favicon_url),
         {:ok, avatar_id} <- process_favicon(image_data) do
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
    else
      {:error, reason} ->
        Logger.info(
          "bots.favicon_fetcher: skipping favicon for bot #{bot.id}: #{inspect(reason)}"
        )
    end

    :ok
  end

  defp find_favicon_url(feed_url) do
    site_url = extract_site_url(feed_url)

    case HTTPClient.get_html(site_url) do
      {:ok, %{body: body}} ->
        favicon_url = pick_favicon(body, site_url)
        {:ok, favicon_url}

      {:error, _} ->
        {:ok, site_url <> "/favicon.ico"}
    end
  end

  defp extract_site_url(feed_url) do
    uri = URI.parse(feed_url)
    %URI{scheme: uri.scheme, host: uri.host, port: uri.port} |> URI.to_string()
  end

  defp pick_favicon(html, site_url) do
    links = extract_link_tags(html)

    # Priority order: apple-touch-icon > largest icon > shortcut icon > /favicon.ico
    apple =
      Enum.find(links, fn l ->
        l.rel in ["apple-touch-icon", "apple-touch-icon-precomposed"]
      end)

    if apple do
      resolve_url(apple.href, site_url)
    else
      icon_links =
        links
        |> Enum.filter(fn l -> l.rel in ["icon", "shortcut icon"] end)
        |> Enum.sort_by(&parse_icon_size/1, :desc)

      case icon_links do
        [best | _] -> resolve_url(best.href, site_url)
        [] -> site_url <> "/favicon.ico"
      end
    end
  end

  defp extract_link_tags(html) do
    # Simple regex extraction for <link ...> tags
    ~r/<link\s+([^>]+)>/i
    |> Regex.scan(html)
    |> Enum.map(fn [_, attrs] ->
      rel = extract_attr(attrs, "rel")
      href = extract_attr(attrs, "href")
      sizes = extract_attr(attrs, "sizes")
      %{rel: rel || "", href: href || "", sizes: sizes || ""}
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

  defp download_favicon(url) do
    case HTTPClient.get_html(url, max_size: @max_favicon_size) do
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
      # process_upload validates magic bytes, crops to square, re-encodes as WebP
      Avatar.process_upload(tmp_path, nil)
    after
      File.rm(tmp_path)
    end
  end
end
