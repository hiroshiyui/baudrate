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
    |> Ecto.Changeset.change(%{
      status: status,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
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

  describe "paginate_actionable_jobs/1" do
    test "returns only failed and pending jobs" do
      j1 = create_job(%{})
      j2 = create_job(%{})
      j3 = create_job(%{})
      set_status(j1, "delivered")
      set_status(j2, "failed")
      # j3 stays pending

      %{jobs: jobs, total: 2} = DeliveryStats.paginate_actionable_jobs()
      ids = Enum.map(jobs, & &1.id)
      assert j2.id in ids
      assert j3.id in ids
      refute j1.id in ids
    end

    test "pages 50 at a time" do
      for _ <- 1..51, do: create_job(%{})

      assert %{jobs: first, total: 51, total_pages: 2} = DeliveryStats.paginate_actionable_jobs()
      assert length(first) == 50
      assert %{jobs: [_], page: 2} = DeliveryStats.paginate_actionable_jobs(page: 2)
    end

    # The bulk actions act on what the filter shows, so a substring match
    # would sweep up another server's jobs.
    test "filters by the exact domain, not a substring of the inbox" do
      mine = create_job(%{inbox_url: "https://example.com/inbox"})
      _longer = create_job(%{inbox_url: "https://notexample.com/inbox"})
      _suffix = create_job(%{inbox_url: "https://example.com.evil/inbox"})
      _sub = create_job(%{inbox_url: "https://a.example.com/inbox"})

      assert %{jobs: [%{id: id}], total: 1} =
               DeliveryStats.paginate_actionable_jobs(domain: " Example.COM ")

      assert id == mine.id
    end
  end

  describe "waiting_domains/1" do
    test "lists domains with waiting jobs, largest backlog first" do
      for n <- 1..2,
          do: create_job(%{inbox_url: "https://busy.example/inbox", actor_uri: "https://l/#{n}"})

      create_job(%{inbox_url: "https://quiet.example/inbox"})
      create_job(%{inbox_url: "https://done.example/inbox"}) |> set_status("delivered")

      assert DeliveryStats.waiting_domains() == [{"busy.example", 2}, {"quiet.example", 1}]
    end
  end

  describe "retry_job/1" do
    test "resets a failed job to pending" do
      job = create_job(%{}) |> set_status("failed")

      assert {:ok, retried} = DeliveryStats.retry_job(job.id)
      assert retried.status == "pending"
      assert is_nil(retried.next_retry_at)
    end

    # A delivered job put back to pending would send its activity twice.
    test "refuses a job that is not failed" do
      for status <- ~w(delivered abandoned pending) do
        job = create_job(%{}) |> set_status(status)
        assert {:error, :not_found} = DeliveryStats.retry_job(job.id)
        assert Repo.get(DeliveryJob, job.id).status == status
      end
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

    test "refuses a job that already left the queue" do
      job = create_job(%{}) |> set_status("delivered")
      assert {:error, :not_found} = DeliveryStats.abandon_job(job.id)
      assert Repo.get(DeliveryJob, job.id).status == "delivered"
    end

    test "returns error for nonexistent job" do
      assert {:error, :not_found} = DeliveryStats.abandon_job(0)
    end
  end

  describe "retry_all_failed_for_domain/1" do
    test "resets all failed jobs for a domain" do
      j1 =
        create_job(%{
          inbox_url: "https://bad.example/inbox",
          actor_uri: "https://local.example/ap/users/retry1"
        })
        |> set_status("failed")

      j2 =
        create_job(%{
          inbox_url: "https://bad.example/inbox",
          actor_uri: "https://local.example/ap/users/retry2"
        })
        |> set_status("failed")

      j3 = create_job(%{inbox_url: "https://other.example/inbox"}) |> set_status("failed")
      j4 = create_job(%{inbox_url: "https://notbad.example/inbox"}) |> set_status("failed")

      {count, _} = DeliveryStats.retry_all_failed_for_domain("bad.example")
      assert count == 2
      assert Repo.get(DeliveryJob, j4.id).status == "failed"

      assert Repo.get(DeliveryJob, j1.id).status == "pending"
      assert Repo.get(DeliveryJob, j2.id).status == "pending"
      assert Repo.get(DeliveryJob, j3.id).status == "failed"
    end
  end

  describe "abandon_all_for_domain/1" do
    test "abandons all pending/failed jobs for a domain" do
      j1 =
        create_job(%{
          inbox_url: "https://spam.example/inbox",
          actor_uri: "https://local.example/ap/users/spam1"
        })

      j2 =
        create_job(%{
          inbox_url: "https://spam.example/inbox",
          actor_uri: "https://local.example/ap/users/spam2"
        })
        |> set_status("failed")

      j3 = create_job(%{inbox_url: "https://good.example/inbox"})
      j4 = create_job(%{inbox_url: "https://spam.example.org/inbox"})

      {count, _} = DeliveryStats.abandon_all_for_domain("spam.example")
      assert count == 2
      assert Repo.get(DeliveryJob, j4.id).status == "pending"
      assert {0, nil} = DeliveryStats.abandon_all_for_domain("  ")

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
