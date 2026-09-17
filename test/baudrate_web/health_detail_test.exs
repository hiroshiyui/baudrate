defmodule BaudrateWeb.HealthDetailTest do
  # Starts a real listener whose request process reads the database in shared
  # sandbox mode.
  use Baudrate.DataCase, async: false

  import Plug.Test

  alias BaudrateWeb.HealthDetail

  describe "child_spec/1" do
    test "is nil when no port is configured" do
      assert HealthDetail.child_spec(port: nil) == nil
    end

    test "listens on 127.0.0.1 only, and answers GET /health with the report" do
      pid = start_supervised!(HealthDetail.child_spec(port: 0))
      assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)

      response = Req.get!("http://127.0.0.1:#{port}/health", retry: false)

      assert response.status in [200, 503]
      assert ["no-store"] = response.headers["cache-control"]
      assert %{"status" => status, "checks" => checks} = response.body
      assert status in ["ok", "fail"]
      assert checks["database"]["status"] == "ok"
      assert response.status == 200 == (status == "ok")
    end

    test "the address is not configurable" do
      %{start: {Bandit, :start_link, [opts]}} = HealthDetail.child_spec(port: 4999)
      assert opts[:ip] == {127, 0, 0, 1}
    end
  end

  describe "call/2" do
    test "answers 404 to anything but GET /health" do
      for {method, path} <- [{:get, "/"}, {:get, "/metrics"}, {:post, "/health"}] do
        conn = HealthDetail.call(conn(method, path), [])
        assert conn.status == 404, "#{method} #{path}"
      end
    end
  end
end
