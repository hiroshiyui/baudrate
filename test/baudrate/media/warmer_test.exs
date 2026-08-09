defmodule Baudrate.Media.WarmerTest do
  @moduledoc """
  Warming is opportunistic — `BaudrateWeb.MediaController` fetches on demand
  anyway — so what is worth pinning is the *extraction*: which URLs it decides
  are remote images, and the caps that stop a single hostile document from
  triggering an unbounded fan-out of outbound fetches.
  """
  use Baudrate.DataCase, async: false

  alias Baudrate.Media.{Cache, Warmer}
  alias Baudrate.Federation.HTTPClient

  # 1x1 PNG — the smallest thing libvips will accept and re-encode.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    # Warming is off in the test env by default so an incidental outbound fetch
    # cannot make unrelated tests depend on the HTTP stub. These tests are
    # exactly the ones that want it on.
    previous = Application.get_env(:baudrate, :media_warm_enabled)
    Application.put_env(:baudrate, :media_warm_enabled, true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:baudrate, :media_warm_enabled)
        value -> Application.put_env(:baudrate, :media_warm_enabled, value)
      end
    end)

    :ok
  end

  defp stub_image do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    Req.Test.stub(HTTPClient, fn conn ->
      Agent.update(agent, &[conn.request_path | &1])

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, @png)
    end)

    agent
  end

  defp fetched_paths(agent), do: agent |> Agent.get(& &1) |> Enum.sort()

  defp uncached_url(name),
    do: "https://remote.example/#{name}-#{System.unique_integer([:positive])}.png"

  describe "warm_html/1" do
    test "is total for anything that is not HTML" do
      assert Warmer.warm_html(nil) == :ok
      assert Warmer.warm_html("") == :ok
      assert Warmer.warm_html(%{not: "a string"}) == :ok
      assert Warmer.warm_html(12_345) == :ok
    end

    test "caches remote images referenced in the document" do
      agent = stub_image()
      url = uncached_url("warm")

      assert Warmer.warm_html(~s(<p>hi</p><img src="#{url}" alt="x">)) == :ok

      assert {:ok, _path} = Cache.cached_path(url)
      assert fetched_paths(agent) != []
    end

    test "ignores same-origin images, which need no proxying" do
      agent = stub_image()

      html = """
      <img src="/uploads/article_images/local.webp">
      <img src="/media/sig/encoded">
      <img src="data:image/png;base64,iVBORw0KGgo=">
      """

      assert Warmer.warm_html(html) == :ok
      assert fetched_paths(agent) == []
    end

    test "recognises a protocol-relative src but refuses to guess its scheme" do
      # `//host/path` is the classic way to smuggle a third-party request past
      # a scheme-matching filter, so the extractor deliberately matches it —
      # but `HTTPClient.validate_url/1` then refuses it as `:https_required`,
      # because inventing a scheme would mean inventing a request target. The
      # net effect is a placeholder, never an outbound fetch.
      #
      # Unreachable from stored content in practice: Ammonia drops an <img>
      # whose src is not https://, http://, /uploads/, or /media/ — see
      # `Baudrate.Media.Rewriter`. This pins the belt-and-braces layer.
      assert Baudrate.Sanitizer.Native.sanitize_federation(~s(<img src="//remote.example/x.png">)) ==
               ""

      agent = stub_image()
      url = "//remote.example/proto-relative-#{System.unique_integer([:positive])}.png"

      assert Warmer.warm_html(~s(<img src="#{url}">)) == :ok
      assert fetched_paths(agent) == []
      assert Cache.cached_path(url) == :miss
    end

    test "unescapes &amp; so the fetched URL matches the one the page will request" do
      # A query string survives HTML escaping as &amp;. Warming the escaped
      # form would cache under a different digest than the proxy later asks
      # for, quietly making every warm a miss.
      agent = stub_image()
      uid = System.unique_integer([:positive])
      url = "https://remote.example/q-#{uid}.png?a=1&b=2"

      assert Warmer.warm_html(~s(<img src="https://remote.example/q-#{uid}.png?a=1&amp;b=2">)) ==
               :ok

      assert fetched_paths(agent) != []
      assert {:ok, _} = Cache.cached_path(url)
    end

    test "caps a single document at 8 fetches" do
      agent = stub_image()
      uid = System.unique_integer([:positive])

      html =
        Enum.map_join(1..30, "\n", fn n ->
          ~s(<img src="https://remote.example/many-#{uid}-#{n}.png">)
        end)

      assert Warmer.warm_html(html) == :ok
      assert length(fetched_paths(agent)) == 8
    end

    test "deduplicates before applying the cap" do
      agent = stub_image()
      uid = System.unique_integer([:positive])
      repeated = ~s(<img src="https://remote.example/dupe-#{uid}.png">)

      assert Warmer.warm_html(String.duplicate(repeated <> "\n", 12)) == :ok
      assert length(fetched_paths(agent)) == 1
    end
  end

  describe "warm_urls/1" do
    test "is total for anything that is not a list of URLs" do
      assert Warmer.warm_urls(nil) == :ok
      assert Warmer.warm_urls("https://remote.example/x.png") == :ok
      assert Warmer.warm_urls([]) == :ok
    end

    test "skips non-binary entries rather than crashing the caller" do
      agent = stub_image()
      url = uncached_url("mixed")

      assert Warmer.warm_urls([url, nil, 42, %{}]) == :ok
      assert length(fetched_paths(agent)) == 1
    end

    test "a fetch failure is swallowed — warming is never load-bearing" do
      Req.Test.stub(HTTPClient, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      url = uncached_url("broken")
      assert Warmer.warm_urls([url]) == :ok
      assert Cache.cached_path(url) == :miss
    end

    test "an already-cached URL is not re-fetched" do
      agent = stub_image()
      url = uncached_url("twice")

      assert Warmer.warm_urls([url]) == :ok
      assert length(fetched_paths(agent)) == 1

      assert Warmer.warm_urls([url]) == :ok
      assert length(fetched_paths(agent)) == 1
    end

    test "does nothing at all when warming is disabled" do
      Application.put_env(:baudrate, :media_warm_enabled, false)
      agent = stub_image()

      assert Warmer.warm_urls([uncached_url("disabled")]) == :ok
      assert fetched_paths(agent) == []
    end
  end
end
