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

  # Compared after percent-decoding, because `Plug.Static` decodes each
  # segment before it touches the disk: `/uploads/dm%5Fimages/<file>` used to
  # pass the raw comparison here and then be served from `dm_images/`.
  @impl true
  def call(%Plug.Conn{path_info: [a, b | _]} = conn, _opts) do
    if [decode(a), decode(b)] in @prefixes do
      conn |> send_resp(404, "") |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  # A malformed escape cannot name a directory `Plug.Static` would serve
  # (it refuses the request itself), so the raw segment is compared.
  defp decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end
end
