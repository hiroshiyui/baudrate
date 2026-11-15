defmodule BaudrateWeb.Plugs.DenyPrivateUploadsTest do
  use BaudrateWeb.ConnCase, async: true

  # Both trees are reachable through a controller only: DM images after a
  # participant check (ADR 0071), proxy copies through the HMAC-signed
  # `/media` URL. nginx refuses the same prefixes; this is the second line.
  #
  # Each case writes a real file, so a 404 means the plug refused it rather
  # than that nothing was there.
  defp put_file(subdir) do
    # Where `Plug.Static` would find it, whatever a subsystem's own setting.
    dir = Application.app_dir(:baudrate, Path.join(["priv", "static", "uploads", subdir]))
    File.mkdir_p!(dir)
    name = "#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}.webp"
    path = Path.join(dir, name)
    File.write!(path, "RIFF....WEBP")
    on_exit(fn -> File.rm(path) end)
    name
  end

  test "a direct-message image is not served by path", %{conn: conn} do
    name = put_file("dm_images")
    assert get(conn, "/uploads/dm_images/#{name}").status == 404
  end

  test "a media-cache copy is not served by path", %{conn: conn} do
    name = put_file("media_cache")
    assert get(conn, "/uploads/media_cache/#{name}").status == 404
  end

  # `Plug.Static` decodes each segment before reading the disk; the plug used
  # to compare the raw segment, so an escaped underscore walked past it.
  test "a percent-encoded prefix is refused too", %{conn: conn} do
    dm = put_file("dm_images")
    cache = put_file("media_cache")

    assert get(conn, "/uploads/dm%5Fimages/#{dm}").status == 404
    assert get(conn, "/uploads/dm%5fimages/#{dm}").status == 404
    assert get(conn, "/uploads/media%5Fcache/#{cache}").status == 404
    assert get(conn, "/%75ploads/dm_images/#{dm}").status == 404
  end

  test "a public upload is served with nosniff", %{conn: conn} do
    name = put_file("article_images")
    conn = get(conn, "/uploads/article_images/#{name}")

    assert conn.status == 200
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end
end
