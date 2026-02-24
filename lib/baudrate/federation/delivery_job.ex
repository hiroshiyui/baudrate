defmodule Baudrate.Federation.DeliveryJob do
  @moduledoc """
  Schema for the delivery queue.

  Each record represents an activity that needs to be POSTed to a remote
  inbox. The `DeliveryWorker` polls for pending/failed jobs and processes
  them via `Delivery.deliver_one/1`.

  ## Status Lifecycle

      pending → delivered
      pending → failed (with next_retry_at for backoff)
      failed  → delivered (on successful retry)
      failed  → abandoned (after max attempts exhausted)
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "delivery_jobs" do
    field :activity_json, :string
    field :inbox_url, :string
    field :actor_uri, :string
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :next_retry_at, :utc_datetime
    field :delivered_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(activity_json inbox_url actor_uri)a

  @doc """
  Changeset for creating a new delivery job.
  """
  def create_changeset(job \\ %__MODULE__{}, attrs) do
    job
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Marks a job as successfully delivered.
  """
  def mark_delivered(job) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    job
    |> change(%{
      status: "delivered",
      delivered_at: now,
      attempts: job.attempts + 1
    })
  end

  @doc """
  Marks a job as failed with the next retry time based on backoff schedule.

  If max attempts are exhausted, marks as abandoned instead.
  """
  def mark_failed(job, error_message) do
    config = Application.get_env(:baudrate, Baudrate.Federation, [])
    backoff_schedule = config[:delivery_backoff_schedule] || [60, 300, 1800, 7200, 43200, 86400]
    max_attempts = config[:delivery_max_attempts] || 6

    new_attempts = job.attempts + 1

    if new_attempts >= max_attempts do
      mark_abandoned(job, error_message)
    else
      backoff_index = min(new_attempts - 1, length(backoff_schedule) - 1)
      backoff_seconds = Enum.at(backoff_schedule, backoff_index)

      next_retry =
        DateTime.utc_now() |> DateTime.add(backoff_seconds, :second) |> DateTime.truncate(:second)

      job
      |> change(%{
        status: "failed",
        attempts: new_attempts,
        last_error: truncate_error(error_message),
        next_retry_at: next_retry
      })
    end
  end

  @doc """
  Marks a job as abandoned (no more retries).
  """
  def mark_abandoned(job, error_message \\ nil) do
    changes = %{
      status: "abandoned",
      attempts: job.attempts + 1
    }

    changes =
      if error_message do
        Map.put(changes, :last_error, truncate_error(error_message))
      else
        changes
      end

    job |> change(changes)
  end

  defp truncate_error(msg) when is_binary(msg), do: String.slice(msg, 0, 1000)
  defp truncate_error(msg), do: msg |> inspect() |> String.slice(0, 1000)
end
