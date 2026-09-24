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

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  schema "delivery_jobs" do
    field :activity_json, :string
    # The activity's `id` (or a hash of the JSON when it has none). Pending and
    # failed jobs are unique per (inbox_url, actor_uri, activity_id).
    field :activity_id, :string
    field :inbox_url, :string
    # The inbox's host, downcased: the key of the per-domain circuit breaker
    # (`DeliveryCircuits`).
    field :domain, :string
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

  `activity_id` is derived from `activity_json`: the activity's `id`, or an
  MD5 of the JSON when it has none. It is the dedup key alongside the inbox
  and actor. `domain` is derived from `inbox_url`.
  """
  def create_changeset(job \\ %__MODULE__{}, attrs) do
    job
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> put_activity_id()
    |> put_domain()
  end

  @doc """
  Returns the activity id used as the dedup key for `activity_json`: its `id`,
  or an MD5 of the JSON when it has none.
  """
  @spec activity_id_for(String.t()) :: String.t()
  def activity_id_for(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"id" => id}} when is_binary(id) and id != "" -> id
      _ -> :crypto.hash(:md5, json) |> Base.encode16(case: :lower)
    end
  end

  @doc """
  Returns the downcased host of an inbox URL, or `nil` when it has none.
  """
  @spec domain_of(term()) :: String.t() | nil
  def domain_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  def domain_of(_), do: nil

  defp put_activity_id(%Ecto.Changeset{valid?: true} = changeset) do
    put_change(changeset, :activity_id, activity_id_for(get_field(changeset, :activity_json)))
  end

  defp put_activity_id(changeset), do: changeset

  defp put_domain(%Ecto.Changeset{valid?: true} = changeset) do
    put_change(changeset, :domain, domain_of(get_field(changeset, :inbox_url)))
  end

  defp put_domain(changeset), do: changeset

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
    backoff_schedule = config[:delivery_backoff_schedule] || [60, 300, 1800, 7200, 43_200, 86_400]
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
