defmodule BaudrateWeb.Plugs.RateLimit do
  @moduledoc """
  Plug for IP-based rate limiting via `BaudrateWeb.RateLimiter`.

  ## Usage

      plug BaudrateWeb.Plugs.RateLimit, action: :login
      plug BaudrateWeb.Plugs.RateLimit, action: :totp

  ## Rate Limits

    * `:login` — 10 attempts per 5 minutes per IP
    * `:totp` — 15 attempts per 5 minutes per IP
    * `:activity_pub` — 120 requests per minute per IP
    * `:feeds` — 30 requests per minute per IP
    * `:push_subscription` — 10 requests per minute per IP
    * `:share_target` — 10 requests per minute per IP
    * `:media` — 300 requests per minute per IP (media proxy, cache hits included)

  Registration and password reset are **not** listed here: those flows submit
  over the LiveView channel rather than a plug-routed request, so they check
  their own buckets (`"register:\#{ip}"`, `"password_reset:\#{ip}"`) inside
  `BaudrateWeb.RegisterLive` / `BaudrateWeb.PasswordResetLive`.

  ## Bucket Naming

  Buckets are named `"action:ip"` (e.g., `"login:192.168.1.1"`), so each
  IP is rate-limited independently per action type.

  On rate limit errors (backend failure), the plug **fails open** to avoid
  blocking legitimate users due to infrastructure issues.
  """

  import Plug.Conn
  use Gettext, backend: BaudrateWeb.Gettext
  require Logger

  @behaviour Plug

  @limits %{
    login: {300_000, 10},
    totp: {300_000, 15},
    activity_pub: {60_000, 120},
    feeds: {60_000, 30},
    push_subscription: {60_000, 10},
    share_target: {60_000, 10},
    media: {60_000, 300}
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    action = Keyword.fetch!(opts, :action)
    {scale_ms, limit} = Map.fetch!(@limits, action)
    ip = remote_ip(conn)
    bucket = "#{action}:#{ip}"

    case BaudrateWeb.RateLimiter.check_rate(bucket, scale_ms, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        Logger.warning("rate_limit.denied: action=#{action} ip=#{ip}")

        if action in [:activity_pub, :push_subscription, :media] do
          # Machine-readable clients (remote AP instances, the push service
          # worker, an <img> element) get the untranslated HTTP status phrase,
          # not a full HTML page.
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(429, Jason.encode!(%{error: "Too Many Requests"}))
          |> halt()
        else
          conn
          |> put_resp_content_type("text/html")
          |> send_resp(429, too_many_requests_html())
          |> halt()
        end

      {:error, reason} ->
        Logger.error("rate_limit.error: action=#{action} reason=#{inspect(reason)}")
        # Fail open to avoid blocking legitimate users on backend errors
        conn
    end
  end

  defp remote_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  # Minimal standalone 429 page. This plug halts before the router (and before
  # any layout is available), so the document is assembled here. Both the
  # locale tag and the message come from Gettext; the message is HTML-escaped
  # because translations are interpolated into markup.
  defp too_many_requests_html do
    title = gettext("Too many requests")
    message = gettext("Too many requests. Please try again later.")
    lang = Gettext.get_locale(BaudrateWeb.Gettext) |> String.replace("_", "-")

    """
    <!DOCTYPE html>
    <html lang="#{Plug.HTML.html_escape(lang)}">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{Plug.HTML.html_escape(title)}</title>
      </head>
      <body id="rate-limit-body" class="rate-limit-body">
        <main id="rate-limit-main" class="rate-limit-main">
          <h1 id="rate-limit-heading" class="rate-limit-heading">#{Plug.HTML.html_escape(title)}</h1>
          <p id="rate-limit-message" class="rate-limit-message">#{Plug.HTML.html_escape(message)}</p>
        </main>
      </body>
    </html>
    """
  end
end
