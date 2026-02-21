defmodule Baudrate.Federation.DeliveryStats do
  @moduledoc """
  Delivery queue statistics and management for the admin dashboard.

  Provides status counts, error rate metrics, and administrative
  actions (retry, abandon) for delivery jobs.
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Federation.DeliveryJob

  @doc """
  Returns a map of status → count for all delivery jobs.
  """
  @spec status_counts() :: map()
  def status_counts do
    from(j in DeliveryJob,
      group_by: j.status,
      select: {j.status, count(j.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns actionable jobs (failed/pending), ordered by most recent first.
  """
  @spec list_actionable_jobs(non_neg_integer()) :: [DeliveryJob.t()]
  def list_actionable_jobs(limit \\ 50) do
    from(j in DeliveryJob,
      where: j.status in ["failed", "pending"],
      order_by: [desc: j.updated_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Resets a failed job to pending for retry.
  """
  @spec retry_job(integer()) :: {:ok, DeliveryJob.t()} | {:error, term()}
  def retry_job(job_id) do
    case Repo.get(DeliveryJob, job_id) do
      nil ->
        {:error, :not_found}

      job ->
        job
        |> Ecto.Changeset.change(%{status: "pending", next_retry_at: nil})
        |> Repo.update()
    end
  end

  @doc """
  Marks a job as abandoned (no further retries).
  """
  @spec abandon_job(integer()) :: {:ok, DeliveryJob.t()} | {:error, term()}
  def abandon_job(job_id) do
    case Repo.get(DeliveryJob, job_id) do
      nil ->
        {:error, :not_found}

      job ->
        job
        |> Ecto.Changeset.change(%{status: "abandoned"})
        |> Repo.update()
    end
  end

  @doc """
  Retries all failed jobs targeting inboxes on the given domain.
  Returns `{count, nil}`.
  """
  @spec retry_all_failed_for_domain(String.t()) :: {non_neg_integer(), nil}
  def retry_all_failed_for_domain(domain) when is_binary(domain) do
    pattern = "%#{domain}%"

    from(j in DeliveryJob,
      where: j.status == "failed" and like(j.inbox_url, ^pattern)
    )
    |> Repo.update_all(set: [status: "pending", next_retry_at: nil])
  end

  @doc """
  Abandons all pending/failed jobs targeting inboxes on the given domain.
  Returns `{count, nil}`.
  """
  @spec abandon_all_for_domain(String.t()) :: {non_neg_integer(), nil}
  def abandon_all_for_domain(domain) when is_binary(domain) do
    pattern = "%#{domain}%"

    from(j in DeliveryJob,
      where: j.status in ["pending", "failed"] and like(j.inbox_url, ^pattern)
    )
    |> Repo.update_all(set: [status: "abandoned"])
  end

  @doc """
  Returns the error rate over the last 24 hours as a float between 0.0 and 1.0.

  Error rate = (failed + abandoned) / (delivered + failed + abandoned).
  Returns 0.0 when no completed jobs exist in the time window.
  """
  @spec error_rate_24h() :: float()
  def error_rate_24h do
    cutoff = DateTime.utc_now() |> DateTime.add(-86400, :second)

    counts =
      from(j in DeliveryJob,
        where: j.updated_at >= ^cutoff and j.status in ["delivered", "failed", "abandoned"],
        group_by: j.status,
        select: {j.status, count(j.id)}
      )
      |> Repo.all()
      |> Map.new()

    delivered = Map.get(counts, "delivered", 0)
    failed = Map.get(counts, "failed", 0)
    abandoned = Map.get(counts, "abandoned", 0)
    total = delivered + failed + abandoned

    if total == 0, do: 0.0, else: (failed + abandoned) / total
  end
end
