defmodule BaudrateWeb.Plugs.DenyPrivateUploadsTest do
  use BaudrateWeb.ConnCase, async: true

  # Both trees are reachable through a controller only: DM images after a
  # participant check (ADR 0071), proxy copies through the HMAC-signed
  # `/media` URL. nginx refuses the same prefixes; this is the second line.
  test "a direct-message image is not served by path", %{conn: conn} do
    conn = get(conn, "/uploads/dm_images/#{String.duplicate("a", 64)}.webp")
    assert conn.status == 404
  end

  test "a media-cache copy is not served by path", %{conn: conn} do
    conn = get(conn, "/uploads/media_cache/#{String.duplicate("b", 64)}.webp")
    assert conn.status == 404
  end
end
