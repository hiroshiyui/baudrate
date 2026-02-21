defmodule Baudrate.Federation.InstanceStats do
  @moduledoc """
  Computes per-domain statistics from existing federation data.

  Aggregates remote actor counts, follower counts, and content counts
  (articles, comments) by domain, derived from the `remote_actors`,
  `followers`, `articles`, and `comments` tables.
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Content.{Article, Comment}
  alias Baudrate.Federation.{Follower, RemoteActor}

  @doc """
  Returns a list of maps with per-domain stats, sorted by actor count descending.

  Each map contains:
    * `:domain` — the remote instance domain
    * `:actor_count` — number of known remote actors
    * `:last_seen` — most recent `fetched_at` for any actor on that domain
    * `:follower_count` — number of follower relationships from that domain
    * `:article_count` — number of articles from actors on that domain
    * `:comment_count` — number of comments from actors on that domain
  """
  @spec list_instances() :: [map()]
  def list_instances do
    # Base: group remote actors by domain
    domain_stats =
      from(ra in RemoteActor,
        group_by: ra.domain,
        select: %{
          domain: ra.domain,
          actor_count: count(ra.id),
          last_seen: max(ra.fetched_at)
        },
        order_by: [desc: count(ra.id)]
      )
      |> Repo.all()

    if domain_stats == [] do
      []
    else
      domains = Enum.map(domain_stats, & &1.domain)

      # Follower counts per domain: count followers whose remote_actor belongs to domain
      follower_counts =
        from(f in Follower,
          join: ra in RemoteActor,
          on: f.remote_actor_id == ra.id,
          where: ra.domain in ^domains,
          group_by: ra.domain,
          select: {ra.domain, count(f.id)}
        )
        |> Repo.all()
        |> Map.new()

      # Article counts per domain
      article_counts =
        from(a in Article,
          join: ra in RemoteActor,
          on: a.remote_actor_id == ra.id,
          where: ra.domain in ^domains and is_nil(a.deleted_at),
          group_by: ra.domain,
          select: {ra.domain, count(a.id)}
        )
        |> Repo.all()
        |> Map.new()

      # Comment counts per domain
      comment_counts =
        from(c in Comment,
          join: ra in RemoteActor,
          on: c.remote_actor_id == ra.id,
          where: ra.domain in ^domains and is_nil(c.deleted_at),
          group_by: ra.domain,
          select: {ra.domain, count(c.id)}
        )
        |> Repo.all()
        |> Map.new()

      Enum.map(domain_stats, fn stat ->
        Map.merge(stat, %{
          follower_count: Map.get(follower_counts, stat.domain, 0),
          article_count: Map.get(article_counts, stat.domain, 0),
          comment_count: Map.get(comment_counts, stat.domain, 0)
        })
      end)
    end
  end

  @doc """
  Returns stats for a single domain, or nil if no actors exist for that domain.
  """
  @spec instance_detail(String.t()) :: map() | nil
  def instance_detail(domain) when is_binary(domain) do
    case list_instances() |> Enum.find(&(&1.domain == domain)) do
      nil -> nil
      stats -> Map.put(stats, :actors, list_actors_for_domain(domain))
    end
  end

  @doc """
  Returns all remote actors for the given domain.
  """
  @spec list_actors_for_domain(String.t()) :: [RemoteActor.t()]
  def list_actors_for_domain(domain) when is_binary(domain) do
    from(ra in RemoteActor,
      where: ra.domain == ^domain,
      order_by: [desc: ra.fetched_at]
    )
    |> Repo.all()
  end
end
