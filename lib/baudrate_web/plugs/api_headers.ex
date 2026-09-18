defmodule BaudrateWeb.Plugs.ApiHeaders do
  @moduledoc """
  Baseline security headers for responses that are not browser pages.

  `put_secure_browser_headers/1` lives in the `:browser` pipeline, so the
  `:api`, `:feeds` and `:activity_pub` pipelines and the media proxy sent no
  CSP, no `x-content-type-options` and no `x-frame-options` at all. It is
  marginal on current browsers — `application/rss+xml` and
  `application/activity+json` are not sniffed as HTML, and the feed bodies are
  escaped and CDATA-guarded — but a sniffing client fetching `/feeds/rss`, full
  of member-authored titles, had nothing telling it not to, and the AP JSON
  carried no `frame-ancestors`.

  Deliberately minimal and not the browser set: these responses load no
  subresources of their own, so the policy denies everything rather than
  allowing `'self'`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    )
  end
end
