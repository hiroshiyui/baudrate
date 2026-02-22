defmodule BaudrateWeb.Plugs.AttachmentHeaders do
  @moduledoc """
  Plug to set `Content-Disposition` and `X-Content-Type-Options` headers
  on attachment file responses.

  Matches requests to `/uploads/attachments/*` and uses `register_before_send`
  to add response headers before `Plug.Static` sends the file:

    * **Images** (`image/jpeg`, `image/png`, `image/webp`, `image/gif`):
      kept inline with `x-content-type-options: nosniff`
    * **Non-images** (PDF, ZIP, etc.): forced download via
      `content-disposition: attachment` with `x-content-type-options: nosniff`

  This prevents non-image files (especially PDFs) from executing JavaScript
  in the site's origin context when rendered inline by browsers.

  Must be placed **before** `Plug.Static` in the endpoint.
  """

  import Plug.Conn

  @behaviour Plug

  @safe_image_types [
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/gif"
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/uploads/attachments/" <> _} = conn, _opts) do
    register_before_send(conn, fn conn ->
      content_type = get_resp_header(conn, "content-type") |> List.first("")

      conn = put_resp_header(conn, "x-content-type-options", "nosniff")

      if Enum.any?(@safe_image_types, &String.starts_with?(content_type, &1)) do
        conn
      else
        put_resp_header(conn, "content-disposition", "attachment")
      end
    end)
  end

  def call(conn, _opts), do: conn
end
