defmodule Baudrate.Federation.DeliveryWorkerTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation.{DeliveryJob, DeliveryWorker}

  describe "init/1" do
    test "starts and schedules polling" do
      # The worker is already running in the supervision tree.
      # Verify it's alive.
      assert Process.alive?(Process.whereis(DeliveryWorker))
    end
  end

  describe "poll processing" do
    test "picks up pending jobs" do
      # Insert a pending job
      {:ok, job} =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/test"
        })
        |> Repo.insert()

      assert job.status == "pending"

      # Trigger a poll manually
      send(Process.whereis(DeliveryWorker), :poll)

      # Give it time to process
      Process.sleep(200)

      # The job should have been attempted (will fail since inbox is fake,
      # but status should change from pending)
      updated = Repo.get!(DeliveryJob, job.id)
      assert updated.status in ["failed", "abandoned"]
      assert updated.attempts >= 1
    end

    test "does not pick up future retry jobs" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      {:ok, job} =
        %DeliveryJob{}
        |> Ecto.Changeset.change(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/test",
          status: "failed",
          attempts: 1,
          next_retry_at: future
        })
        |> Repo.insert()

      # Trigger a poll
      send(Process.whereis(DeliveryWorker), :poll)
      Process.sleep(200)

      # Job should not have been touched
      updated = Repo.get!(DeliveryJob, job.id)
      assert updated.attempts == 1
    end

    test "does not process delivered jobs" do
      {:ok, job} =
        %DeliveryJob{}
        |> Ecto.Changeset.change(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/test",
          status: "delivered",
          attempts: 1,
          delivered_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      send(Process.whereis(DeliveryWorker), :poll)
      Process.sleep(200)

      updated = Repo.get!(DeliveryJob, job.id)
      assert updated.status == "delivered"
      assert updated.attempts == 1
    end

    test "does not process abandoned jobs" do
      {:ok, job} =
        %DeliveryJob{}
        |> Ecto.Changeset.change(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/test",
          status: "abandoned",
          attempts: 6
        })
        |> Repo.insert()

      send(Process.whereis(DeliveryWorker), :poll)
      Process.sleep(200)

      updated = Repo.get!(DeliveryJob, job.id)
      assert updated.status == "abandoned"
      assert updated.attempts == 6
    end
  end
end
