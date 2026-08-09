defmodule Baudrate.Media.NegativeCacheTest do
  use ExUnit.Case, async: false

  alias Baudrate.Media.NegativeCache

  setup do
    NegativeCache.clear()
    on_exit(&NegativeCache.clear/0)
    :ok
  end

  test "an unseen URL has not failed" do
    refute NegativeCache.failed?("https://remote.example/never-seen.png")
  end

  test "mark_failed/1 suppresses retries for that URL only" do
    url = "https://remote.example/broken.png"
    assert NegativeCache.mark_failed(url) == :ok
    assert NegativeCache.failed?(url)
    refute NegativeCache.failed?("https://remote.example/other.png")
  end

  test "clear/0 forgets every failure" do
    NegativeCache.mark_failed("https://remote.example/a.png")
    NegativeCache.mark_failed("https://remote.example/b.png")

    assert NegativeCache.clear() == :ok

    refute NegativeCache.failed?("https://remote.example/a.png")
    refute NegativeCache.failed?("https://remote.example/b.png")
  end

  test "an expired entry is reported as not failed even before the sweep runs" do
    url = "https://remote.example/expired.png"
    # The sweep only reclaims memory; `failed?/1` compares the stored expiry
    # itself, so a stale row must never keep suppressing a retry.
    :ets.insert(NegativeCache, {url, System.system_time(:second) - 1})
    refute NegativeCache.failed?(url)
  end

  test "the periodic sweep deletes expired rows and keeps live ones" do
    live = "https://remote.example/live.png"
    stale = "https://remote.example/stale.png"

    NegativeCache.mark_failed(live)
    :ets.insert(NegativeCache, {stale, System.system_time(:second) - 60})

    send(Process.whereis(NegativeCache), :sweep)
    # Round-trip a call through the GenServer so the cast-like send is drained.
    _ = :sys.get_state(NegativeCache)

    assert :ets.lookup(NegativeCache, stale) == []
    assert NegativeCache.failed?(live)
  end
end
