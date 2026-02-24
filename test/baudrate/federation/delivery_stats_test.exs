defmodule Baudrate.Federation.DeliveryStatsTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.{DeliveryJob, DeliveryStats}

  defp create_job(attrs) do
    uid = System.unique_integer([:positive])

    default = %{
      activity_json: ~s({"type":"Create","id":"#{uid}"}),
      inbox_url: "https://remote-#{uid}.example/inbox",
      actor_uri: "https://local.example/ap/users/alice-#{uid}"
    }

    {:ok, job} =
      DeliveryJob.create_changeset(Map.merge(default, attrs))
      |> Repo.insert()

    job
  end

  defp set_status(job, status) do
    job
    |> Ecto.Changeset.change(%{status: status, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update!()
  end

  describe "status_counts/0" do
    test "returns empty map when no jobs" do
      assert DeliveryStats.status_counts() == %{}
    end

    test "returns counts per status" do
      j1 = create_job(%{})
      j2 = create_job(%{})
      _j3 = create_job(%{})
      set_status(j1, "delivered")
      set_status(j2, "failed")

      counts = DeliveryStats.status_counts()
      assert counts["pending"] == 1
      assert counts["delivered"] == 1
      assert counts["failed"] == 1
    end
  end

  describe "list_actionable_jobs/1" do
    test "returns only failed and pending jobs" do
      j1 = create_job(%{})
      j2 = create_job(%{})
      j3 = create_job(%{})
      set_status(j1, "delivered")
      set_status(j2, "failed")
      # j3 stays pending

      jobs = DeliveryStats.list_actionable_jobs()
      ids = Enum.map(jobs, & &1.id)
      assert j2.id in ids
      assert j3.id in ids
      refute j1.id in ids
    end

    test "respects limit" do
      for _ <- 1..5, do: create_job(%{})

      assert length(DeliveryStats.list_actionable_jobs(3)) == 3
    end
  end

  describe "retry_job/1" do
    test "resets a failed job to pending" do
      job = create_job(%{}) |> set_status("failed")

      assert {:ok, retried} = DeliveryStats.retry_job(job.id)
      assert retried.status == "pending"
      assert is_nil(retried.next_retry_at)
    end

    test "returns error for nonexistent job" do
      assert {:error, :not_found} = DeliveryStats.retry_job(0)
    end
  end

  describe "abandon_job/1" do
    test "marks a job as abandoned" do
      job = create_job(%{})

      assert {:ok, abandoned} = DeliveryStats.abandon_job(job.id)
      assert abandoned.status == "abandoned"
    end

    test "returns error for nonexistent job" do
      assert {:error, :not_found} = DeliveryStats.abandon_job(0)
    end
  end

  describe "retry_all_failed_for_domain/1" do
    test "resets all failed jobs for a domain" do
      j1 = create_job(%{inbox_url: "https://bad.example/inbox", actor_uri: "https://local.example/ap/users/retry1"}) |> set_status("failed")
      j2 = create_job(%{inbox_url: "https://bad.example/inbox", actor_uri: "https://local.example/ap/users/retry2"}) |> set_status("failed")
      j3 = create_job(%{inbox_url: "https://other.example/inbox"}) |> set_status("failed")

      {count, _} = DeliveryStats.retry_all_failed_for_domain("bad.example")
      assert count == 2

      assert Repo.get(DeliveryJob, j1.id).status == "pending"
      assert Repo.get(DeliveryJob, j2.id).status == "pending"
      assert Repo.get(DeliveryJob, j3.id).status == "failed"
    end
  end

  describe "abandon_all_for_domain/1" do
    test "abandons all pending/failed jobs for a domain" do
      j1 = create_job(%{inbox_url: "https://spam.example/inbox", actor_uri: "https://local.example/ap/users/spam1"})
      j2 = create_job(%{inbox_url: "https://spam.example/inbox", actor_uri: "https://local.example/ap/users/spam2"}) |> set_status("failed")
      j3 = create_job(%{inbox_url: "https://good.example/inbox"})

      {count, _} = DeliveryStats.abandon_all_for_domain("spam.example")
      assert count == 2

      assert Repo.get(DeliveryJob, j1.id).status == "abandoned"
      assert Repo.get(DeliveryJob, j2.id).status == "abandoned"
      assert Repo.get(DeliveryJob, j3.id).status == "pending"
    end
  end

  describe "error_rate_24h/0" do
    test "returns 0.0 when no completed jobs" do
      assert DeliveryStats.error_rate_24h() == 0.0
    end

    test "calculates error rate correctly" do
      # 3 delivered, 1 failed, 1 abandoned → rate = 2/5 = 0.4
      for _ <- 1..3 do
        create_job(%{}) |> set_status("delivered")
      end

      create_job(%{}) |> set_status("failed")
      create_job(%{}) |> set_status("abandoned")

      assert_in_delta DeliveryStats.error_rate_24h(), 0.4, 0.01
    end
  end
end
