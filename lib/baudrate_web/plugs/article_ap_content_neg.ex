defmodule BaudrateWeb.Plugs.ArticleApContentNeg do
  @moduledoc """
  Content-negotiates the public article URL `/articles/:slug` so remote
  ActivityPub implementations can discover an article from its human URL.

  When a `GET /articles/:slug` request advertises an ActivityPub-compatible
  Accept header (`application/activity+json`, `application/ld+json`, or
  `application/json`), this plug forwards to
  `BaudrateWeb.ActivityPubController.article/2` and halts the connection,
  returning the AS2 JSON object directly. Browser requests fall through to
  `BaudrateWeb.ArticleLive` unchanged.

  ## What is never intercepted

  Two guards, because the segment count alone is not enough:

    * **Segment count** — the match is `["articles", slug]` exactly, so the
      three-segment `/articles/:slug/edit` and `/articles/:slug/history` fall
      through.
    * **Reserved segments** — `/articles/new` is *also* two segments, so the
      count does not exclude it. Today it is saved only by router scope order
      (the `:authenticated` scope is declared before `:public_browsable`, so
      the request never reaches this plug), which is a load-bearing coupling to
      a declaration order in another file. `@reserved_slugs` makes the
      guarantee local. Nothing is lost by it: `Content.generate_slug/1` always
      appends a random suffix, for remote articles as well as local ones, so no
      article can ever hold one of these slugs.
  """

  import Plug.Conn

  alias BaudrateWeb.ActivityPubController

  @ap_accept_types ["application/activity+json", "application/ld+json", "application/json"]

  # Literal path segments that are routes in their own right, not article slugs.
  @reserved_slugs ["new"]

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", path_info: ["articles", slug]} = conn, _opts)
      when slug not in @reserved_slugs do
    if wants_ap?(conn) do
      conn
      |> put_resp_header("vary", "Accept")
      |> ActivityPubController.article(%{"slug" => slug})
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp wants_ap?(conn) do
    accept = conn |> get_req_header("accept") |> List.first("")
    Enum.any?(@ap_accept_types, &String.contains?(accept, &1))
  end
end
