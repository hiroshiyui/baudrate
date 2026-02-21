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
end
