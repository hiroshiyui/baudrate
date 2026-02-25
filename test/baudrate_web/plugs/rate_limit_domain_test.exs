defmodule BaudrateWeb.Plugs.RateLimitDomainTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias BaudrateWeb.Plugs.RateLimitDomain

  @evil_domain "evil.example"
  @good_domain "good.example"

  setup :verify_on_exit!

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
      # No Hammer call expected since there's no remote actor
      conn = build_conn() |> call_plug()

      refute conn.halted
    end

    test "passes through under rate limit" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _bucket, _scale, _limit ->
        {:allow, 1}
      end)

      conn = build_conn(mock_actor(@evil_domain)) |> call_plug()

      refute conn.halted
    end

    test "returns 429 when rate limit exceeded" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _bucket, _scale, _limit ->
        {:deny, 60}
      end)

      conn = build_conn(mock_actor(@evil_domain)) |> call_plug()

      assert conn.halted
      assert conn.status == 429
    end

    test "response body is JSON error on 429" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _bucket, _scale, _limit ->
        {:deny, 60}
      end)

      conn = build_conn(mock_actor(@evil_domain)) |> call_plug()

      assert %{"error" => "Rate limited"} = Jason.decode!(conn.resp_body)
    end

    test "response content-type is application/json on 429" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _bucket, _scale, _limit ->
        {:deny, 60}
      end)

      conn = build_conn(mock_actor(@evil_domain)) |> call_plug()

      [content_type | _] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "logs warning with domain on 429" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _bucket, _scale, _limit ->
        {:deny, 60}
      end)

      log =
        capture_log(fn ->
          build_conn(mock_actor(@evil_domain)) |> call_plug()
        end)

      assert log =~ "federation.domain_rate_limited"
      assert log =~ @evil_domain
    end

    test "per-domain isolation: uses domain in bucket key" do
      expect(BaudrateWeb.RateLimiterMock, :check_rate, fn bucket, _scale, _limit ->
        assert bucket == "ap_domain:#{@evil_domain}"
        {:deny, 60}
      end)

      expect(BaudrateWeb.RateLimiterMock, :check_rate, fn bucket, _scale, _limit ->
        assert bucket == "ap_domain:#{@good_domain}"
        {:allow, 1}
      end)

      evil_conn = build_conn(mock_actor(@evil_domain)) |> call_plug()
      assert evil_conn.halted
      assert evil_conn.status == 429

      good_conn = build_conn(mock_actor(@good_domain)) |> call_plug()
      refute good_conn.halted
    end
  end

  describe "error path (fail-open)" do
    test "passes through on backend error" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _bucket, _scale, _limit ->
        {:error, :backend_down}
      end)

      conn = build_conn(mock_actor(@evil_domain)) |> call_plug()

      refute conn.halted
    end

    test "logs error on backend failure" do
      stub(BaudrateWeb.RateLimiterMock, :check_rate, fn _bucket, _scale, _limit ->
        {:error, :backend_down}
      end)

      log =
        capture_log(fn ->
          build_conn(mock_actor(@evil_domain)) |> call_plug()
        end)

      assert log =~ "federation.rate_limit_error"
      assert log =~ "backend_down"
    end
  end
end
