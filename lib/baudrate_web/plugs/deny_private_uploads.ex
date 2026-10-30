defmodule BaudrateWeb.Plugs.DenyPrivateUploads do
  @moduledoc """
  Answers 404 for any path under `/uploads/dm_images/` (ADR 0071) or
  `/uploads/media_cache/` before `Plug.Static` can serve it.

  Direct-message images live in the uploads tree so the nightly backup keeps
  them, but they are private: the only way to read one is
  `/messages/images/:id`, after a participant check. Their filenames are
  never shown to a client, so this is the second line, not the first; nginx
  refuses the same prefix in front of the application.
  """

  @behaviour Plug

  import Plug.Conn

  # `media_cache` holds the proxy's re-encoded copies, reachable through
  # `MediaController` only: served by path they would bypass the HMAC that
  # keeps `/media` from being an open proxy, and the deterministic file name
  # would tell anyone whether this instance has fetched a given remote image.
  @prefixes [["uploads", "dm_images"], ["uploads", "media_cache"]]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [a, b | _]} = conn, _opts)
      when [a, b] in @prefixes do
    conn |> send_resp(404, "") |> halt()
  end

  def call(conn, _opts), do: conn
end
