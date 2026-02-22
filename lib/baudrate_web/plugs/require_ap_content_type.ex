defmodule BaudrateWeb.Plugs.RequireAPContentType do
  @moduledoc """
  Plug to validate that ActivityPub inbox requests have an appropriate
  content type.

  Accepts:
    * `application/activity+json`
    * `application/ld+json`
    * `application/json`

  Rejects all other content types with `415 Unsupported Media Type`.
  Uses `String.starts_with?/2` to handle charset parameters
  (e.g., `application/json; charset=utf-8`).
  """

  import Plug.Conn

  @behaviour Plug

  @accepted_types [
    "application/activity+json",
    "application/ld+json",
    "application/json"
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    content_type =
      case get_req_header(conn, "content-type") do
        [value | _] -> String.downcase(value)
        [] -> ""
      end

    if Enum.any?(@accepted_types, &String.starts_with?(content_type, &1)) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(415, Jason.encode!(%{error: "Unsupported Media Type"}))
      |> halt()
    end
  end
end
