defmodule Baudrate.Federation.DeliveryStats do
  @moduledoc """
  Delivery queue statistics and management for the admin pages
  (`/admin/federation` and `/admin/federation/delivery`, Phase 7E).

  Provides status counts, error rate metrics, a paged job list filtered by
  domain, and administrative actions (retry, abandon), one job at a time or
  for every job of one domain.
  """

  import Ecto.Query

  alias Baudrate.Federation.DeliveryJob
  alias Baudrate.{Pagination, Repo}

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

  @per_page 50

  @doc """
  One page of the jobs an admin can act on — `pending` and `failed` —
  most recently touched first, for `/admin/federation/delivery`.

  Options: `:page` (default 1) and `:domain`, which matches the job's stored
  `domain` **exactly**. A substring match on the inbox URL would take
  `example.com` to mean `notexample.com` and `example.com.evil` as well, and
  the bulk actions act on whatever the filter shows.

  Returns `%{jobs: [...], total: n, page: p, total_pages: t}`.
  """
  @spec paginate_actionable_jobs(keyword()) :: %{
          jobs: [DeliveryJob.t()],
          total: non_neg_integer(),
          page: pos_integer(),
          total_pages: pos_integer()
        }
  def paginate_actionable_jobs(opts \\ []) do
    pagination = Pagination.paginate_opts(opts, @per_page)

    actionable_query(Keyword.get(opts, :domain))
    |> Pagination.paginate_query(pagination,
      result_key: :jobs,
      order_by: [desc: dynamic([j], j.updated_at), desc: dynamic([j], j.id)],
      preloads: []
    )
  end

  @doc """
  The domains that have jobs waiting, with how many each, largest backlog
  first — the choices for the delivery page's filter. At most `limit`.
  """
  @spec waiting_domains(pos_integer()) :: [{String.t(), non_neg_integer()}]
  def waiting_domains(limit \\ 50) do
    from(j in DeliveryJob,
      where: j.status in ["pending", "failed"] and not is_nil(j.domain),
      group_by: j.domain,
      select: {j.domain, count(j.id)},
      order_by: [desc: count(j.id), asc: j.domain],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp actionable_query(domain) do
    query = from(j in DeliveryJob, where: j.status in ["failed", "pending"])

    case normalize_domain(domain) do
      nil -> query
      domain -> where(query, [j], j.domain == ^domain)
    end
  end

  @doc """
  The form a job's `domain` is stored in (`DeliveryJob.domain_of/1`): a bare,
  downcased host. `nil` for a blank value.
  """
  @spec normalize_domain(term()) :: String.t() | nil
  def normalize_domain(domain) when is_binary(domain) do
    case domain |> String.trim() |> String.downcase() do
      "" -> nil
      host -> host
    end
  end

  def normalize_domain(_), do: nil

  @doc """
  Queues a **failed** job for another attempt now. Any other job is refused
  with `{:error, :not_found}`: a delivered job put back to `pending` would
  send its activity a second time, and a pending one is already queued.
  """
  @spec retry_job(integer()) :: {:ok, DeliveryJob.t()} | {:error, :not_found}
  def retry_job(job_id) do
    transition(job_id, ["failed"], status: "pending", next_retry_at: nil)
  end

  @doc """
  Gives up on a `pending` or `failed` job. A delivered or already abandoned
  job is refused with `{:error, :not_found}`.
  """
  @spec abandon_job(integer()) :: {:ok, DeliveryJob.t()} | {:error, :not_found}
  def abandon_job(job_id) do
    transition(job_id, ["pending", "failed"], status: "abandoned")
  end

  # One conditional UPDATE, so a job the worker finishes meanwhile is not
  # dragged back into a state it has left.
  defp transition(job_id, from_statuses, changes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(j in DeliveryJob,
      where: j.id == ^job_id and j.status in ^from_statuses,
      select: j
    )
    |> Repo.update_all(set: Keyword.put(changes, :updated_at, now))
    |> case do
      {1, [job]} -> {:ok, job}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Retries every failed job for exactly `domain`. Returns `{count, nil}`.
  """
  @spec retry_all_failed_for_domain(String.t()) :: {non_neg_integer(), nil}
  def retry_all_failed_for_domain(domain) when is_binary(domain) do
    case normalize_domain(domain) do
      nil ->
        {0, nil}

      domain ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        from(j in DeliveryJob, where: j.status == "failed" and j.domain == ^domain)
        |> Repo.update_all(set: [status: "pending", next_retry_at: nil, updated_at: now])
    end
  end

  @doc """
  Abandons every pending and failed job for exactly `domain`. Returns
  `{count, nil}`.
  """
  @spec abandon_all_for_domain(String.t()) :: {non_neg_integer(), nil}
  def abandon_all_for_domain(domain) when is_binary(domain) do
    case normalize_domain(domain) do
      nil ->
        {0, nil}

      domain ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        from(j in DeliveryJob,
          where: j.status in ["pending", "failed"] and j.domain == ^domain
        )
        |> Repo.update_all(set: [status: "abandoned", updated_at: now])
    end
  end

  @doc """
  Returns the error rate over the last 24 hours as a float between 0.0 and 1.0.

  Error rate = (failed + abandoned) / (delivered + failed + abandoned).
  Returns 0.0 when no completed jobs exist in the time window.
  """
  @spec error_rate_24h() :: float()
  def error_rate_24h do
    cutoff = DateTime.utc_now() |> DateTime.add(-86_400, :second)

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
