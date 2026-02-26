defmodule Baudrate.Federation.DeliveryJobTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.DeliveryJob

  describe "create_changeset/2" do
    test "valid changeset with all required fields" do
      changeset =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/alice"
        })

      assert changeset.valid?
    end

    test "missing activity_json is invalid" do
      changeset =
        DeliveryJob.create_changeset(%{
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/alice"
        })

      refute changeset.valid?
      assert %{activity_json: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing inbox_url is invalid" do
      changeset =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          actor_uri: "https://local.example/ap/users/alice"
        })

      refute changeset.valid?
      assert %{inbox_url: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing actor_uri is invalid" do
      changeset =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox"
        })

      refute changeset.valid?
      assert %{actor_uri: ["can't be blank"]} = errors_on(changeset)
    end

    test "defaults to pending status" do
      {:ok, job} =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/alice"
        })
        |> Repo.insert()

      assert job.status == "pending"
      assert job.attempts == 0
      assert is_nil(job.next_retry_at)
    end
  end

  describe "mark_delivered/1" do
    test "sets status to delivered with timestamp" do
      {:ok, job} =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/alice"
        })
        |> Repo.insert()

      {:ok, delivered} = job |> DeliveryJob.mark_delivered() |> Repo.update()

      assert delivered.status == "delivered"
      assert delivered.attempts == 1
      assert delivered.delivered_at != nil
    end
  end

  describe "mark_failed/2" do
    test "sets status to failed with next_retry_at" do
      {:ok, job} =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/alice"
        })
        |> Repo.insert()

      {:ok, failed} = job |> DeliveryJob.mark_failed("connection refused") |> Repo.update()

      assert failed.status == "failed"
      assert failed.attempts == 1
      assert failed.last_error == "connection refused"
      assert failed.next_retry_at != nil
    end

    test "marks as abandoned after max attempts" do
      {:ok, job} =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/alice"
        })
        |> Repo.insert()

      # Simulate 5 previous attempts
      job = %{job | attempts: 5}

      {:ok, abandoned} = job |> DeliveryJob.mark_failed("still failing") |> Repo.update()

      assert abandoned.status == "abandoned"
      assert abandoned.attempts == 6
      assert abandoned.last_error == "still failing"
    end
  end

  describe "mark_abandoned/1" do
    test "sets status to abandoned" do
      {:ok, job} =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/alice"
        })
        |> Repo.insert()

      {:ok, abandoned} = job |> DeliveryJob.mark_abandoned("domain_blocked") |> Repo.update()

      assert abandoned.status == "abandoned"
      assert abandoned.last_error == "domain_blocked"
    end
  end

  describe "retry flow" do
    test "exponential backoff increases next_retry_at with each attempt" do
      {:ok, job} =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/alice"
        })
        |> Repo.insert()

      # First failure
      {:ok, failed1} = job |> DeliveryJob.mark_failed("error") |> Repo.update()
      assert failed1.status == "failed"
      assert failed1.attempts == 1
      retry1 = failed1.next_retry_at

      # Second failure — next_retry_at should be further out
      {:ok, failed2} = failed1 |> DeliveryJob.mark_failed("error") |> Repo.update()
      assert failed2.attempts == 2
      assert DateTime.compare(failed2.next_retry_at, retry1) == :gt
    end

    test "full retry cycle from pending to abandoned" do
      {:ok, job} =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/alice"
        })
        |> Repo.insert()

      max_attempts = Application.get_env(:baudrate, :delivery_max_attempts, 6)

      # Fail through all attempts
      final =
        Enum.reduce(1..max_attempts, job, fn _i, j ->
          {:ok, failed} = j |> DeliveryJob.mark_failed("connection refused") |> Repo.update()
          failed
        end)

      assert final.status == "abandoned"
      assert final.attempts == max_attempts
      assert final.last_error == "connection refused"
    end

    test "failed job can still be marked delivered on retry success" do
      {:ok, job} =
        DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://remote.example/inbox",
          actor_uri: "https://local.example/ap/users/alice"
        })
        |> Repo.insert()

      # Fail once
      {:ok, failed} = job |> DeliveryJob.mark_failed("timeout") |> Repo.update()
      assert failed.status == "failed"

      # Then succeed on retry
      {:ok, delivered} = failed |> DeliveryJob.mark_delivered() |> Repo.update()
      assert delivered.status == "delivered"
      assert delivered.attempts == 2
      assert delivered.delivered_at != nil
    end
  end
end
