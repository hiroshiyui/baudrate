defmodule Baudrate.Federation.StaleActorCleaner do
  @moduledoc """
  GenServer that periodically cleans up stale remote actors from the cache.

  Remote actors are cached in `remote_actors` with `fetched_at` timestamps.
  Actors that haven't been refreshed within the configured max age are either:

  - **Refreshed** — if they are still referenced by followers, articles,
    comments, likes, announces, or reports
  - **Deleted** — if they have no remaining references in the database

  Runs every 24 hours (configurable via `stale_actor_cleanup_interval`).
  Actors older than 30 days are considered stale (configurable via
  `stale_actor_max_age`). Processing is batched (50 actors per batch)
  to avoid long-running transactions.

  Skips cleanup when federation is disabled.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Federation.{ActorResolver, Announce, Follower, RemoteActor}
  alias Baudrate.Content.{Article, ArticleLike, Comment}
  alias Baudrate.Moderation.Report

  @batch_size 50

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    if Baudrate.Setup.federation_enabled?() do
      run_cleanup()
    end

    schedule_cleanup()
    {:noreply, state}
  end

  @doc """
  Runs the stale actor cleanup process immediately.

  Returns `{refreshed, deleted, errors}` counts.
  """
  @spec run_cleanup() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def run_cleanup do
    max_age = config(:stale_actor_max_age) || 2_592_000
    cutoff = DateTime.utc_now() |> DateTime.add(-max_age, :second) |> DateTime.truncate(:second)

    {refreshed, deleted, errors} = process_stale_batch(cutoff, MapSet.new(), {0, 0, 0})

    if refreshed > 0 or deleted > 0 or errors > 0 do
      Logger.info(
        "federation.stale_actor_cleanup: refreshed=#{refreshed} deleted=#{deleted} errors=#{errors}"
      )
    end

    {refreshed, deleted, errors}
  end

  @doc """
  Checks whether a remote actor has any references in the database.

  Returns `true` if the actor is referenced by any of:
  followers, articles, comments, article likes, announces, or reports.
  Short-circuits on the first match found.
  """
  @spec has_references?(non_neg_integer()) :: boolean()
  def has_references?(remote_actor_id) do
    Repo.exists?(from f in Follower, where: f.remote_actor_id == ^remote_actor_id) or
      Repo.exists?(from a in Article, where: a.remote_actor_id == ^remote_actor_id) or
      Repo.exists?(from c in Comment, where: c.remote_actor_id == ^remote_actor_id) or
      Repo.exists?(from l in ArticleLike, where: l.remote_actor_id == ^remote_actor_id) or
      Repo.exists?(from n in Announce, where: n.remote_actor_id == ^remote_actor_id) or
      Repo.exists?(from r in Report, where: r.remote_actor_id == ^remote_actor_id)
  end

  defp process_stale_batch(cutoff, skip_ids, {refreshed, deleted, errors}) do
    skip_list = MapSet.to_list(skip_ids)

    batch =
      from(r in RemoteActor,
        where: r.fetched_at < ^cutoff and r.id not in ^skip_list,
        order_by: [asc: r.fetched_at],
        limit: @batch_size
      )
      |> Repo.all()

    if batch == [] do
      {refreshed, deleted, errors}
    else
      {batch_refreshed, batch_deleted, batch_errors, new_skip_ids} =
        Enum.reduce(batch, {0, 0, 0, skip_ids}, fn actor, {r, d, e, skips} ->
          if has_references?(actor.id) do
            case ActorResolver.refresh(actor.ap_id) do
              {:ok, _} -> {r + 1, d, e, skips}
              {:error, _} -> {r, d, e + 1, MapSet.put(skips, actor.id)}
            end
          else
            case Repo.delete(actor) do
              {:ok, _} -> {r, d + 1, e, skips}
              {:error, _} -> {r, d, e + 1, MapSet.put(skips, actor.id)}
            end
          end
        end)

      process_stale_batch(
        cutoff,
        new_skip_ids,
        {refreshed + batch_refreshed, deleted + batch_deleted, errors + batch_errors}
      )
    end
  end

  defp schedule_cleanup do
    interval = config(:stale_actor_cleanup_interval) || 86_400_000
    Process.send_after(self(), :cleanup, interval)
  end

  defp config(key) do
    Application.get_env(:baudrate, Baudrate.Federation, []) |> Keyword.get(key)
  end
end
