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

  The match is restricted to exactly two path segments (`["articles", slug]`)
  so sibling routes like `/articles/new`, `/articles/:slug/edit`, and
  `/articles/:slug/history` are never intercepted.
  """

  import Plug.Conn

  alias BaudrateWeb.ActivityPubController

  @ap_accept_types ["application/activity+json", "application/ld+json", "application/json"]

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", path_info: ["articles", slug]} = conn, _opts) do
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
