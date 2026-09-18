defmodule Baudrate.Media.CacheTest do
  use ExUnit.Case, async: false

  alias Baudrate.Media.Cache

  # `fetch_and_store/1` refuses a redirect into a blocked domain, and that
  # check reads the domain-block cache, which reads the Repo.
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Baudrate.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Baudrate.Repo, {:shared, self()})
    :ok
  end

  # A 1x1 PNG — smallest input libvips will actually decode.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    on_exit(fn -> clear_cache() end)
    clear_cache()
    :ok
  end

  defp clear_cache do
    dir = Cache.cache_dir()

    case File.ls(dir) do
      {:ok, names} -> Enum.each(names, &File.rm(Path.join(dir, &1)))
      {:error, _} -> :ok
    end
  end

  defp stub(fun), do: Req.Test.stub(Baudrate.Federation.HTTPClient, fun)

  defp unique_url, do: "https://remote.example/img-#{System.unique_integer([:positive])}.png"

  describe "digest/1" do
    test "is a stable sha256 hex with no input-derived characters" do
      digest = Cache.digest("https://remote.example/../../etc/passwd")

      assert String.length(digest) == 64
      assert digest =~ ~r/\A[0-9a-f]+\z/
      assert digest == Cache.digest("https://remote.example/../../etc/passwd")
    end
  end

  describe "fetch_and_store/1" do
    test "stores a re-encoded WebP under the URL digest" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, @png) end)
      url = unique_url()

      assert {:ok, path} = Cache.fetch_and_store(url)
      assert Path.basename(path) == Cache.digest(url) <> ".webp"
      assert File.regular?(path)

      # Re-encoded, not passed through: the stored bytes are not the PNG.
      stored = File.read!(path)
      refute stored == @png
      assert binary_part(stored, 0, 4) == "RIFF"

      assert {:ok, ^path} = Cache.cached_path(url)
    end

    test "rejects a non-image body by magic bytes" do
      # An HTML error page served with a 200 must not become a cached "image".
      stub(fn conn ->
        Plug.Conn.send_resp(conn, 200, "<!doctype html><html><body>nope</body></html>")
      end)

      assert {:error, :invalid_image} = Cache.fetch_and_store(unique_url())
    end

    test "rejects SVG" do
      # SVG can carry script, so it is never accepted or served.
      svg = ~s[<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>]
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, svg) end)

      assert {:error, :invalid_image} = Cache.fetch_and_store(unique_url())
    end

    test "rejects an oversized body" do
      oversized = String.duplicate("a", 6 * 1024 * 1024)
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, oversized) end)

      assert {:error, reason} = Cache.fetch_and_store(unique_url())
      assert reason in [:image_too_large, :response_too_large]
    end

    test "surfaces a remote error as an atom" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, :http_error} = Cache.fetch_and_store(unique_url())
    end

    test "leaves no temp files behind on failure" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "<!doctype html>") end)

      assert {:error, _} = Cache.fetch_and_store(unique_url())

      assert {:ok, names} = File.ls(Cache.cache_dir())
      assert Enum.filter(names, &String.contains?(&1, ".tmp.")) == []
    end
  end

  describe "cached_path/1" do
    test "returns :miss for an uncached URL" do
      assert Cache.cached_path(unique_url()) == :miss
    end
  end

  describe "purge_stale/2" do
    test "removes entries older than the TTL and keeps fresh ones" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, @png) end)

      {:ok, old} = Cache.fetch_and_store(unique_url())
      {:ok, fresh} = Cache.fetch_and_store(unique_url())

      # 40 days ago, well past the 30-day default.
      old_time = System.os_time(:second) - 40 * 86_400
      File.touch!(old, old_time)

      assert Cache.purge_stale() >= 1
      refute File.regular?(old)
      assert File.regular?(fresh)
    end

    test "evicts oldest-first when over the size ceiling" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, @png) end)

      {:ok, older} = Cache.fetch_and_store(unique_url())
      {:ok, newer} = Cache.fetch_and_store(unique_url())

      now = System.os_time(:second)
      File.touch!(older, now - 100)
      File.touch!(newer, now)

      # A ceiling of 1 byte forces eviction down to (almost) nothing.
      assert Cache.purge_stale(30, 1) >= 1
      refute File.regular?(older)
    end

    test "disk_usage/0 counts stored bytes" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, @png) end)
      assert Cache.disk_usage() == 0

      {:ok, path} = Cache.fetch_and_store(unique_url())
      assert Cache.disk_usage() == File.stat!(path).size
    end
  end
end
