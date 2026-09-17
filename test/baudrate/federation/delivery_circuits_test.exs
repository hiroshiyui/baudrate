defmodule Baudrate.Federation.DeliveryCircuitsTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.{DeliveryCircuit, DeliveryCircuits}

  @domain "flaky.example"

  describe "outcome/1" do
    test "connection failures, timeouts, 5xx and 429 say the server is unreachable" do
      for result <- [
            {:error, {:request_failed, %{reason: :econnrefused}}},
            {:error, :dns_resolution_failed},
            {:error, :timeout},
            {:error, {:http_error, 500, ""}},
            {:error, {:http_error, 503, "busy"}},
            {:error, {:http_error, 429, ""}}
          ] do
        assert DeliveryCircuits.outcome(result) == :unreachable, inspect(result)
      end
    end

    test "any other response says the server is reachable" do
      for result <- [
            {:ok, %{status: 202}},
            {:error, {:http_error, 401, ""}},
            {:error, {:http_error, 404, ""}},
            {:error, {:http_error, 410, ""}},
            {:error, :response_too_large}
          ] do
        assert DeliveryCircuits.outcome(result) == :reachable, inspect(result)
      end
    end

    test "failures on our side count for nothing" do
      for result <- [
            {:error, :unknown_actor},
            {:error, :no_private_key},
            {:error, :private_ip},
            {:error, :https_required}
          ] do
        assert DeliveryCircuits.outcome(result) == :neutral, inspect(result)
      end
    end
  end

  describe "record/3" do
    test "the circuit opens at the threshold, for the first step of the schedule" do
      for _ <- 1..(DeliveryCircuits.threshold() - 1) do
        assert DeliveryCircuits.record(@domain, :unreachable, :econnrefused) == :ok
      end

      assert %DeliveryCircuit{trips: 0, open_until: nil} = circuit()

      assert DeliveryCircuits.record(@domain, :unreachable, :econnrefused) == :opened

      circuit = circuit()
      assert circuit.trips == 1
      assert circuit.failures == DeliveryCircuits.threshold()
      assert_in_delta DateTime.diff(circuit.open_until, DateTime.utc_now()), 300, 5
      assert circuit.last_error == ":econnrefused"
    end

    test "failures of jobs already in flight when it opened do not extend it" do
      open(trips: 1, open_until_in: 300)
      before = circuit().open_until

      assert DeliveryCircuits.record(@domain, :unreachable, :timeout) == :ok

      assert %DeliveryCircuit{trips: 1, open_until: ^before} = circuit()
    end

    test "a failed probe reopens it for the next step, capped at the last" do
      open(trips: 1, open_until_in: -1)
      assert DeliveryCircuits.record(@domain, :unreachable, :timeout) == :opened
      assert %DeliveryCircuit{trips: 2} = circuit = circuit()
      assert_in_delta DateTime.diff(circuit.open_until, DateTime.utc_now()), 1800, 5

      open(trips: 12, open_until_in: -1)
      assert DeliveryCircuits.record(@domain, :unreachable, :timeout) == :opened
      assert_in_delta DateTime.diff(circuit().open_until, DateTime.utc_now()), 86_400, 5
    end

    test "a reachable result closes an open circuit" do
      open(trips: 2, open_until_in: 600)

      assert DeliveryCircuits.record(@domain, :reachable) == :closed
      refute Repo.get(DeliveryCircuit, @domain)
    end

    test "a reachable result resets failures below the threshold" do
      DeliveryCircuits.record(@domain, :unreachable, :timeout)

      assert DeliveryCircuits.record(@domain, :reachable) == :ok
      refute Repo.get(DeliveryCircuit, @domain)
    end

    test "neutral results and a missing domain change nothing" do
      assert DeliveryCircuits.record(@domain, :neutral, :unknown_actor) == :ok
      assert DeliveryCircuits.record(nil, :unreachable, :timeout) == :ok
      assert Repo.aggregate(DeliveryCircuit, :count) == 0
    end
  end

  describe "list_tripped/0 and purge_idle/0" do
    test "lists only circuits that opened, and purges rows idle for 30 days" do
      open(trips: 1, open_until_in: 60)
      DeliveryCircuits.record("counting.example", :unreachable, :timeout)

      assert [%DeliveryCircuit{domain: @domain}] = DeliveryCircuits.list_tripped()

      old = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)

      Repo.update_all(from(c in DeliveryCircuit, where: c.domain == @domain),
        set: [updated_at: old]
      )

      assert DeliveryCircuits.purge_idle() == 1
      assert [%DeliveryCircuit{domain: "counting.example"}] = Repo.all(DeliveryCircuit)
    end
  end

  defp circuit, do: Repo.get!(DeliveryCircuit, @domain)

  defp open(trips: trips, open_until_in: seconds) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(
      %DeliveryCircuit{
        domain: @domain,
        failures: 5,
        trips: trips,
        open_until: DateTime.add(now, seconds, :second)
      },
      on_conflict: {:replace, [:trips, :open_until]},
      conflict_target: :domain
    )
  end
end
