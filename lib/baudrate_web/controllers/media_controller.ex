defmodule BaudrateWeb.MediaController do
  @moduledoc """
  Serves remote images from a local, re-encoded copy.

  This is the only way a remote image reaches a viewer's browser. The page emits
  `/media/<signature>/<encoded-url>` (see `Baudrate.Media.Proxy`), and this
  controller verifies the signature, serves the cached WebP, or fetches it once
  and caches it. The viewer's browser never contacts the remote host, so no IP
  address, User-Agent, or reading time is disclosed to it.

  ## Not an open proxy

  The signature is an HMAC over the URL under a key derived from
  `secret_key_base`, so only URLs this instance itself emitted into a page can
  be requested. Beyond that, every fetch still goes through
  `Federation.HTTPClient` (HTTPS-only, DNS-pinned, private-IP-rejecting,
  redirect-revalidating, size-capped), is magic-byte validated, and is
  re-encoded through libvips — the remote's bytes and headers are never
  forwarded.

  ## Responses

  | Situation | Response |
  |---|---|
  | Cache hit | 200 `image/webp`, immutable cache-control, ETag |
  | Matching `if-none-match` | 304 |
  | Cache miss, fetch succeeds | 200, as above |
  | Bad or forged signature | 404 |
  | Fetch failed / too large / not an image | 302 to a local placeholder |
  | Rate limited | 429 (not negative-cached) |
  """

  use BaudrateWeb, :controller

  require Logger

  alias Baudrate.Media.{Cache, NegativeCache, Proxy}
  alias BaudrateWeb.RateLimits

  @placeholder "/images/media-unavailable.svg"

  def show(conn, %{"sig" => signature, "encoded" => encoded}) do
    case Proxy.verify(signature, encoded) do
      {:ok, url} -> serve(conn, url)
      {:error, _reason} -> send_resp(conn, 404, "")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "")

  defp serve(conn, url) do
    case Cache.cached_path(url) do
      {:ok, path} ->
        Cache.touch(path)
        send_image(conn, path, url)

      :miss ->
        if NegativeCache.failed?(url) do
          placeholder(conn)
        else
          fetch_and_serve(conn, url)
        end
    end
  end

  defp fetch_and_serve(conn, url) do
    host = URI.parse(url).host

    with :ok <- refuse_blocked_domain(host),
         :ok <- RateLimits.check_media_fetch_global(),
         :ok <- RateLimits.check_media_fetch_ip(client_ip(conn)),
         :ok <- RateLimits.check_media_fetch_domain(host) do
      case Cache.fetch_and_store(url) do
        {:ok, path} ->
          send_image(conn, path, url)

        {:error, _reason} ->
          # Suppress retries for a while: without this, an image referenced from
          # a popular page whose host is down is re-fetched on every view.
          NegativeCache.mark_failed(url)
          placeholder(conn)
      end
    else
      {:error, :domain_blocked} ->
        placeholder(conn)

      {:error, :rate_limited} ->
        # Deliberately not negative-cached — the URL may be perfectly good.
        conn
        |> put_resp_header("retry-after", "60")
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "Too Many Requests"}))
    end
  end

  # A block stops us reaching out, not only listening (ADR 0030). Without this
  # the proxy kept fetching and caching a blocked instance's images, which is
  # both traffic we have decided not to send and a way for its content to stay
  # on the page. Deliberately not negative-cached: unblocking must work at
  # once, and the cache would outlive the decision by an hour.
  defp refuse_blocked_domain(nil), do: :ok

  defp refuse_blocked_domain(host) do
    if Baudrate.Federation.Validator.domain_blocked?(host) do
      {:error, :domain_blocked}
    else
      :ok
    end
  end

  # sobelow_skip ["Traversal.SendFile"]
  defp send_image(conn, path, url) do
    etag = ~s("#{Cache.digest(url)}")

    if etag in get_req_header(conn, "if-none-match") do
      conn
      |> put_resp_header("etag", etag)
      |> send_resp(304, "")
    else
      conn
      |> put_resp_content_type("image/webp")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("etag", etag)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, path)
    end
  end

  # Same-origin so it satisfies `img-src 'self'`, and it keeps the element's
  # sizing so the layout does not shift when an image is unavailable.
  defp placeholder(conn), do: redirect(conn, to: @placeholder)

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
