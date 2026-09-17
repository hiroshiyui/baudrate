defmodule Baudrate.Health.HeartbeatTest do
  use ExUnit.Case, async: true

  alias Baudrate.Health.Heartbeat

  test "records a worker's last completed run in monotonic milliseconds" do
    worker = :"heartbeat_test_#{System.unique_integer([:positive])}"
    assert Heartbeat.last(worker) == nil

    before = System.monotonic_time(:millisecond)
    assert :ok = Heartbeat.beat(worker)

    assert Heartbeat.last(worker) >= before
    assert Heartbeat.uptime_ms() >= 0
  end
end
