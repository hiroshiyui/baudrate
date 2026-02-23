defmodule BaudrateWeb.Plugs.RateLimitDomainTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BaudrateWeb.Plugs.RateLimitDomain

  @evil_domain "evil.example"
  @good_domain "good.example"

  setup do
    Hammer.delete_buckets("ap_domain:#{@evil_domain}")
    Hammer.delete_buckets("ap_domain:#{@good_domain}")

    on_exit(fn ->
      Hammer.delete_buckets("ap_domain:#{@evil_domain}")
      Hammer.delete_buckets("ap_domain:#{@good_domain}")
    end)

    :ok
  end

  defp build_conn(actor \\ nil) do
    conn = Plug.Test.conn(:post, "/ap/inbox")

    if actor do
      Plug.Conn.assign(conn, :remote_actor, actor)
    else
      conn
    end
  end

  defp call_plug(conn), do: RateLimitDomain.call(conn, RateLimitDomain.init([]))

  defp mock_actor(domain), do: %{domain: domain}

  describe "call/2" do
    test "passes through when no remote_actor assigned" do
      conn = build_conn() |> call_plug()

      refute conn.halted
    end

    test "passes through under rate limit" do
      conn = build_conn(mock_actor(@evil_domain)) |> call_plug()

      refute conn.halted
    end

    test "returns 429 after exhausting 60-request limit" do
      actor = mock_actor(@evil_domain)

      # Exhaust the limit (60 per minute)
      for _ <- 1..60 do
        Hammer.check_rate("ap_domain:#{@evil_domain}", 60_000, 60)
      end

      conn = build_conn(actor) |> call_plug()

      assert conn.halted
      assert conn.status == 429
    end

    test "response body is JSON error on 429" do
      actor = mock_actor(@evil_domain)

      for _ <- 1..60 do
        Hammer.check_rate("ap_domain:#{@evil_domain}", 60_000, 60)
      end

      conn = build_conn(actor) |> call_plug()

      assert %{"error" => "Rate limited"} = Jason.decode!(conn.resp_body)
    end

    test "response content-type is application/json on 429" do
      actor = mock_actor(@evil_domain)

      for _ <- 1..60 do
        Hammer.check_rate("ap_domain:#{@evil_domain}", 60_000, 60)
      end

      conn = build_conn(actor) |> call_plug()

      [content_type | _] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "logs warning with domain on 429" do
      actor = mock_actor(@evil_domain)

      for _ <- 1..60 do
        Hammer.check_rate("ap_domain:#{@evil_domain}", 60_000, 60)
      end

      log =
        capture_log(fn ->
          build_conn(actor) |> call_plug()
        end)

      assert log =~ "federation.domain_rate_limited"
      assert log =~ @evil_domain
    end

    test "per-domain isolation: exhausting domain A does not affect domain B" do
      # Exhaust evil domain
      for _ <- 1..60 do
        Hammer.check_rate("ap_domain:#{@evil_domain}", 60_000, 60)
      end

      evil_conn = build_conn(mock_actor(@evil_domain)) |> call_plug()
      assert evil_conn.halted
      assert evil_conn.status == 429

      # Good domain should still pass
      good_conn = build_conn(mock_actor(@good_domain)) |> call_plug()
      refute good_conn.halted
    end
  end
end
