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

  # The federation payload cap (256 KB) applies here, before `Plug.Parsers`
  # decodes anything: its own `length` is the 1 MB sized for uploads, and the
  # `:json` parser matches `application/activity+json`, so without this an
  # unauthenticated inbox POST was JSON-decoded at four times the documented
  # limit before `CacheBody` ever saw it. `Plug.Parsers` turns the shortened
  # read into a 413.
  def read_body(conn, opts) do
    opts = if inbox_request?(conn), do: Keyword.put(opts, :length, inbox_max_size()), else: opts

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

  defp inbox_request?(%Plug.Conn{method: "POST", path_info: path_info}),
    do: List.last(path_info) == "inbox"

  defp inbox_request?(_conn), do: false

  defp inbox_max_size do
    Application.get_env(:baudrate, Baudrate.Federation, [])
    |> Keyword.get(:max_payload_size, 262_144)
  end
end
