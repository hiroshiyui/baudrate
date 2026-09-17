defmodule Baudrate.HealthTest do
  @moduledoc """
  Acceptance gate for Phase 2D: each check in the detailed health report fails
  when its condition is broken, and passes when it is not.
  """

  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.{DeliveryCircuit, DeliveryJob, InboundActivity, RemoteActor}
  alias Baudrate.Health

  @gib 1024 * 1024 * 1024

  describe "report/1" do
    test "is ok when every check passes, and fails when any one fails" do
      assert %{status: :ok, checks: checks} = Health.report(healthy())

      assert Map.keys(checks) |> Enum.sort() ==
               [
                 :backup,
                 :database,
                 :delivery_queue,
                 :disk,
                 :encryption_keys,
                 :inbound_queue,
                 :workers
               ]

      assert %{status: :fail, checks: %{database: %{status: :fail}}} =
               Health.report(Keyword.put(healthy(), :database, fn -> {:error, :down} end))
    end

    test "a check that does not finish in time fails instead of hanging the report" do
      opts =
        healthy()
        |> Keyword.put(:free_space, fn _ -> Process.sleep(1_000) end)
        |> Keyword.put(:timeout_ms, 50)

      assert %{status: :fail, checks: %{disk: %{status: :fail, reason: reason}}} =
               Health.report(opts)

      assert reason =~ "did not finish"
    end

    test "a check that raises fails, without the exception's text" do
      opts = Keyword.put(healthy(), :free_space, fn _ -> raise "secret path /x/y" end)

      assert %{checks: %{disk: %{status: :fail, reason: "raised an error"}}} =
               Health.report(opts)
    end
  end

  describe "database" do
    test "fails when the database does not answer" do
      assert %{status: :ok} = check(:database, [])
      assert %{status: :fail} = check(:database, database: fn -> {:error, :timeout} end)
    end
  end

  describe "delivery_queue" do
    test "fails when a delivery has been due for more than 15 minutes" do
      insert_job(due_minutes_ago: 5)
      assert %{status: :ok, waiting: 1} = check(:delivery_queue)

      insert_job(due_minutes_ago: 16)
      assert %{status: :fail, waiting: 2, oldest_due_seconds: s} = check(:delivery_queue)
      assert s >= 16 * 60
    end

    test "jobs held back by an open circuit are waiting on purpose" do
      insert_job(due_minutes_ago: 120, domain: "down.example")

      Repo.insert!(%DeliveryCircuit{
        domain: "down.example",
        failures: 5,
        trips: 1,
        open_until: DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)
      })

      assert %{status: :ok, waiting: 1, open_circuits: 1} = check(:delivery_queue)
    end

    test "is skipped while federation is switched off" do
      insert_job(due_minutes_ago: 120)
      assert %{status: :skipped} = check(:delivery_queue, federation_enabled?: false)
    end
  end

  describe "inbound_queue" do
    test "fails when an activity has waited more than 10 minutes, and counts recent failures" do
      actor = remote_actor()
      insert_inbound(actor, minutes_ago: 3)
      assert %{status: :ok, pending: 1} = check(:inbound_queue)

      insert_inbound(actor, minutes_ago: 11)
      insert_inbound(actor, minutes_ago: 30, status: "failed")

      assert %{status: :fail, pending: 2, failed_last_24h: 1} = check(:inbound_queue)
    end
  end

  describe "workers" do
    test "fails when a worker has not completed a run for three intervals" do
      now = 10_000_000
      fresh = fn _ -> now - 1_000 end
      assert %{status: :ok} = check(:workers, last_beat: fresh, monotonic_now_ms: now)

      stale = fn
        :feed_worker -> now - 6 * 60_000
        _ -> now - 1_000
      end

      assert %{status: :fail, stale: [:feed_worker], workers: workers} =
               check(:workers, last_beat: stale, monotonic_now_ms: now)

      assert %{status: :fail, last_run_seconds: 360} = workers.feed_worker
    end

    test "a worker that has not run yet is fine just after boot, and stale later" do
      never = fn _ -> nil end

      assert %{status: :ok} = check(:workers, last_beat: never, uptime_ms: 60_000)

      # SessionCleaner runs hourly, so it may be silent for three hours.
      assert %{status: :fail, stale: stale} =
               check(:workers, last_beat: never, uptime_ms: 2 * 3_600_000)

      refute :session_cleaner in stale
      assert :delivery_worker in stale
    end
  end

  describe "disk" do
    test "fails below 1 GiB or 10% of the filesystem, whichever is larger" do
      assert %{status: :ok} = check(:disk, free_space: fn _ -> {:ok, space(50, 100)} end)
      assert %{status: :fail} = check(:disk, free_space: fn _ -> {:ok, space(5, 100)} end)

      assert %{status: :fail, floor_bytes: floor} =
               check(:disk, free_space: fn _ -> {:ok, %{free: div(@gib, 2), total: 4 * @gib}} end)

      assert floor == @gib
    end

    test "fails when free space cannot be read" do
      assert %{status: :fail} = check(:disk, free_space: fn _ -> {:error, "df failed"} end)
    end
  end

  describe "backup" do
    setup do
      dir = Path.join(System.tmp_dir!(), "baudrate-health-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "fails when the newest backup is more than 26 hours old", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "20260915T043000Z"))
      File.mkdir_p!(Path.join(dir, "20260916T043000Z"))

      # 25½ hours after the newest backup started, then 26½.
      assert %{status: :ok, count: 2, newest_age_seconds: 91_800} =
               check(:backup, backup_dir: dir, now: ~U[2026-09-17 06:00:00Z])

      assert %{status: :fail, newest_age_seconds: 95_400} =
               check(:backup, backup_dir: dir, now: ~U[2026-09-17 07:00:00Z])
    end

    test "fails when there is no complete backup; a half-built one does not count", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".incomplete-20260917T043000Z"))

      assert %{status: :fail, reason: "no complete backup found"} =
               check(:backup, backup_dir: dir)
    end

    test "is skipped when no backup directory is configured" do
      assert %{status: :skipped} = check(:backup, backup_dir: nil)
    end
  end

  # --- Fixtures ---

  defp check(name, opts \\ []) do
    Health.report(Keyword.merge(healthy(), [only: [name]] ++ opts)).checks[name]
  end

  describe "encryption keys" do
    test "is ok when every stored secret names a key this instance has" do
      opts = Keyword.put(healthy(), :key_usage, %{"users.totp_secret" => %{"testauth" => 2}})

      assert %{status: :ok, checks: %{encryption_keys: %{status: :ok} = check}} =
               Health.report(opts)

      assert check.separated == %{auth: true, signing: true}
      assert check.keys == %{"users.totp_secret" => %{"testauth" => 2}}
    end

    test "fails when a stored secret needs a key that is not configured" do
      opts =
        Keyword.put(healthy(), :key_usage, %{
          "users.totp_secret" => %{"testauth" => 1, "dropped" => 3}
        })

      assert %{status: :fail, checks: %{encryption_keys: check}} = Health.report(opts)
      assert check.status == :fail
      assert check.reason =~ "not configured"
      assert check.missing_keys == ["dropped"]
    end

    test "counts values still protected by the secret_key_base fallback without failing" do
      opts = Keyword.put(healthy(), :key_usage, %{"users.totp_secret" => %{"legacy" => 4}})

      assert %{status: :ok, checks: %{encryption_keys: %{status: :ok} = check}} =
               Health.report(opts)

      assert check.keys == %{"users.totp_secret" => %{"legacy" => 4}}
    end

    test "counts a value nobody can read as a missing key" do
      opts = Keyword.put(healthy(), :key_usage, %{"users.totp_secret" => %{"unreadable" => 1}})

      assert %{checks: %{encryption_keys: %{status: :fail, missing_keys: ["unreadable"]}}} =
               Health.report(opts)
    end
  end

  defp healthy do
    [
      free_space: fn _ -> {:ok, space(50, 100)} end,
      last_beat: fn _ -> System.monotonic_time(:millisecond) end,
      backup_dir: nil,
      federation_enabled?: true,
      key_usage: %{"users.totp_secret" => %{"testauth" => 1}}
    ]
  end

  defp space(free_gib, total_gib), do: %{free: free_gib * @gib, total: total_gib * @gib}

  defp insert_job(opts) do
    due =
      DateTime.utc_now()
      |> DateTime.add(-Keyword.fetch!(opts, :due_minutes_ago) * 60)
      |> DateTime.truncate(:second)

    domain = Keyword.get(opts, :domain, "remote.example")

    %DeliveryJob{}
    |> DeliveryJob.create_changeset(%{
      activity_json: ~s({"id":"https://local.example/a/#{System.unique_integer([:positive])}"}),
      inbox_url: "https://#{domain}/inbox",
      actor_uri: "https://local.example/ap/users/someone"
    })
    |> Ecto.Changeset.change(status: "failed", attempts: 1, next_retry_at: due)
    |> Repo.insert!()
  end

  defp remote_actor do
    id = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/health-#{id}",
      username: "health_#{id}",
      domain: "remote.example",
      public_key_pem: elem(Baudrate.Federation.KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/health-#{id}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp insert_inbound(actor, opts) do
    at =
      DateTime.utc_now()
      |> DateTime.add(-Keyword.fetch!(opts, :minutes_ago) * 60)
      |> DateTime.truncate(:second)

    status = Keyword.get(opts, :status, "pending")

    Repo.insert!(%InboundActivity{
      activity_id: "#{actor.ap_id}/activities/#{System.unique_integer([:positive])}",
      activity_type: "Like",
      remote_actor_id: actor.id,
      target_type: "shared",
      status: status,
      processed_at: if(status == "pending", do: nil, else: at),
      inserted_at: at,
      updated_at: at
    })
  end
end
