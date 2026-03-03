defmodule BaudrateWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Custom body reader that caches the raw request body in `conn.assigns.raw_body`.

  Used as the `body_reader` option for `Plug.Parsers` so that the original
  unparsed bytes are preserved for HTTP Signature digest verification.

  Without this, `Plug.Parsers` consumes the body (e.g., when the `:json`
  parser matches `application/activity+json` via `+json` subtype), leaving
  `Plug.Conn.read_body/2` returning empty for subsequent readers like
  `CacheBody`.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = update_in(conn.assigns[:raw_body], &((&1 || "") <> body))
        {:ok, body, conn}

      {:more, partial, conn} ->
        conn = update_in(conn.assigns[:raw_body], &((&1 || "") <> partial))
        {:more, partial, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
