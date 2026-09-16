defmodule BaudrateWeb.MediaControllerTest do
  use BaudrateWeb.ConnCase, async: false

  alias Baudrate.Media.{Cache, NegativeCache, Proxy}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    NegativeCache.clear()
    on_exit(fn -> clear_cache() end)
    clear_cache()
    :ok
  end

  defp clear_cache do
    case File.ls(Cache.cache_dir()) do
      {:ok, names} -> Enum.each(names, &File.rm(Path.join(Cache.cache_dir(), &1)))
      {:error, _} -> :ok
    end
  end

  defp stub(fun), do: Req.Test.stub(Baudrate.Federation.HTTPClient, fun)

  defp unique_url, do: "https://remote.example/img-#{System.unique_integer([:positive])}.png"

  describe "show/2" do
    test "fetches on a cache miss and serves a local WebP", %{conn: conn} do
      stub(fn c -> Plug.Conn.send_resp(c, 200, @png) end)
      url = unique_url()

      conn = get(conn, Proxy.url(url))

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/webp"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert get_resp_header(conn, "etag") == [~s("#{Cache.digest(url)}")]
    end

    test "serves a cache hit without a second outbound request", %{conn: conn} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(fn c ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.send_resp(c, 200, @png)
      end)

      url = unique_url()
      path = Proxy.url(url)

      assert get(conn, path).status == 200
      assert get(build_conn(), path).status == 200
      assert Agent.get(counter, & &1) == 1
    end

    test "answers 304 for a matching if-none-match", %{conn: conn} do
      stub(fn c -> Plug.Conn.send_resp(c, 200, @png) end)
      url = unique_url()
      path = Proxy.url(url)

      assert get(conn, path).status == 200

      conn =
        build_conn()
        |> put_req_header("if-none-match", ~s("#{Cache.digest(url)}"))
        |> get(path)

      assert conn.status == 304
    end

    test "answers 404 for a forged signature", %{conn: conn} do
      url = unique_url()
      encoded = Base.url_encode64(url, padding: false)

      conn = get(conn, "/media/#{String.duplicate("a", 32)}/#{encoded}")
      assert conn.status == 404
    end

    test "answers 404 for a signed but local target", %{conn: conn} do
      # A valid signature must not make the endpoint steerable at a local path.
      local = "/etc/passwd"
      conn = get(conn, "/media/#{Proxy.sign(local)}/#{Base.url_encode64(local, padding: false)}")

      assert conn.status == 404
    end

    test "redirects to a local placeholder when the fetch fails", %{conn: conn} do
      stub(fn c -> Plug.Conn.send_resp(c, 500, "") end)

      conn = get(conn, Proxy.url(unique_url()))

      assert redirected_to(conn) == "/images/media-unavailable.svg"
    end

    test "negative cache suppresses a repeat fetch of a failing URL", %{conn: conn} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(fn c ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.send_resp(c, 500, "")
      end)

      path = Proxy.url(unique_url())

      assert redirected_to(get(conn, path)) == "/images/media-unavailable.svg"
      assert redirected_to(get(build_conn(), path)) == "/images/media-unavailable.svg"
      assert Agent.get(counter, & &1) == 1
    end

    test "never fetches an image from a blocked domain", %{conn: conn} do
      # A block stops us reaching out (ADR 0030). Left alone, the proxy kept
      # fetching and caching a blocked instance's images, disclosing every
      # viewer's IP and reading times to it.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(fn c ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.send_resp(c, 200, @png)
      end)

      {:ok, _} = Baudrate.Federation.DomainBlocks.block_domain("blocked.example")
      Baudrate.Federation.DomainBlockCache.refresh()
      on_exit(fn -> Baudrate.Federation.DomainBlockCache.refresh() end)

      url = "https://blocked.example/img-#{System.unique_integer([:positive])}.png"
      conn = get(conn, Proxy.url(url))

      assert redirected_to(conn) == "/images/media-unavailable.svg"
      assert Agent.get(counter, & &1) == 0

      # Not negative-cached: unblocking has to work at once, and a cached
      # failure would outlive the decision by an hour.
      refute NegativeCache.failed?(url)
    end

    test "answers a JSON 429 when rate limited, without negative-caching", %{conn: conn} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(fn c ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.send_resp(c, 200, @png)
      end)

      BaudrateWeb.RateLimiter.Sandbox.set_global_fun(fn bucket, _scale, _limit ->
        if String.starts_with?(bucket, "media_"), do: {:deny, 0}, else: {:allow, 1}
      end)

      url = unique_url()
      conn = get(conn, Proxy.url(url))

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["60"]
      assert conn.resp_body =~ "Too Many Requests"
      assert Agent.get(counter, & &1) == 0

      # A rate-limited URL is not marked dead — it may be perfectly good.
      refute NegativeCache.failed?(url)

      BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})
    end
  end
end
