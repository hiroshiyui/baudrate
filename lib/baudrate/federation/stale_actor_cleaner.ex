defmodule Baudrate.Federation.StaleActorCleaner do
  @moduledoc """
  GenServer that periodically cleans up stale remote actors from the cache.

  Remote actors are cached in `remote_actors` with `fetched_at` timestamps.
  Actors that haven't been refreshed within the configured max age are either:

  - **Refreshed** — if anything in the database still points at them
  - **Deleted** — if nothing does

  "Anything" is read from the database catalog (`referencing_columns/0`), not
  from a list kept in this file. That is deliberate: the list used to be six
  hand-written checks against nineteen foreign keys, and deleting an actor that
  one of the other thirteen still pointed at took real data with it —
  `user_follows`, `timeline_items`, `board_follows`, boosts, likes and poll votes
  cascade on delete, so a member simply lost a follow and every timeline item from
  an account that had gone quiet for a month, while conversations and direct
  messages had their sender set to NULL. A reference added by a future
  migration is covered the moment that migration runs.

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
  alias Baudrate.Federation.{ActorResolver, RemoteActor}

  @batch_size 50

  # Every single-column foreign key pointing at `remote_actors`, straight from
  # the catalog. `conkey` is unnested so a (hypothetical) composite key lists
  # each of its columns.
  @referencing_columns_sql """
  SELECT src.relname, att.attname
  FROM pg_constraint c
  JOIN pg_class src ON src.oid = c.conrelid
  JOIN pg_class tgt ON tgt.oid = c.confrelid
  JOIN unnest(c.conkey) AS k(attnum) ON true
  JOIN pg_attribute att ON att.attrelid = src.oid AND att.attnum = k.attnum
  WHERE c.contype = 'f' AND tgt.relname = 'remote_actors'
  ORDER BY src.relname, att.attname
  """

  # Identifiers come from the catalog, never from a user, but they are
  # interpolated into SQL, so they are checked rather than trusted.
  @identifier ~r/\A[a-z_][a-z0-9_]*\z/

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

    # After the work, not before: a worker that crash-loops is alive and must
    # not look healthy (ADR 0035). This is the fifth periodic worker and was
    # the only one that never beat, so `Baudrate.Health`'s `workers` check
    # could not see it stop — it is documented as a worker in `doc/sysop.md`,
    # which made the report quietly narrower than an operator would read it as.
    # A beat with no entry in `Health.worker_intervals/0` would be equally
    # useless, so the two go together.
    Baudrate.Health.Heartbeat.beat(:stale_actor_cleaner)

    schedule_cleanup()
    {:noreply, state}
  end

  @doc """
  Runs the stale actor cleanup process immediately.

  Returns `{refreshed, deleted, errors}` counts.
  """
  @spec run_cleanup() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def run_cleanup do
    case referencing_columns() do
      [] ->
        # The catalog says nothing points at `remote_actors`, which cannot be
        # true. Something is wrong with the query or the table; treating every
        # actor as unreferenced would delete all of them, so do nothing.
        Logger.error("federation.stale_actor_cleanup: no references found for remote_actors")
        {0, 0, 0}

      columns ->
        max_age = config(:stale_actor_max_age) || 2_592_000

        cutoff =
          DateTime.utc_now() |> DateTime.add(-max_age, :second) |> DateTime.truncate(:second)

        {refreshed, deleted, errors} =
          process_stale_batch(cutoff, columns, MapSet.new(), {0, 0, 0})

        if refreshed > 0 or deleted > 0 or errors > 0 do
          Logger.info(
            "federation.stale_actor_cleanup: refreshed=#{refreshed} deleted=#{deleted} errors=#{errors}"
          )
        end

        {refreshed, deleted, errors}
    end
  end

  @doc """
  Every `{table, column}` in the database that points at `remote_actors`.

  Read from the catalog so that it cannot fall behind the schema. See the
  module doc for why that matters.
  """
  @spec referencing_columns() :: [{String.t(), String.t()}]
  def referencing_columns do
    %{rows: rows} = Repo.query!(@referencing_columns_sql, [])
    Enum.map(rows, fn [table, column] -> {table, column} end)
  end

  @doc """
  Checks whether a remote actor is referenced anywhere in the database.

  Returns `true` if any foreign key in any table points at it.
  """
  @spec has_references?(non_neg_integer()) :: boolean()
  def has_references?(remote_actor_id) do
    referencing_columns()
    |> referenced_ids([remote_actor_id])
    |> MapSet.member?(remote_actor_id)
  end

  defp process_stale_batch(cutoff, columns, skip_ids, {refreshed, deleted, errors}) do
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
      # Resolved for the whole batch, so the number of queries follows the
      # number of referencing columns rather than the number of actors.
      referenced = referenced_ids(columns, Enum.map(batch, & &1.id))

      {batch_refreshed, batch_deleted, batch_errors, new_skip_ids} =
        Enum.reduce(batch, {0, 0, 0, skip_ids}, fn actor, {r, d, e, skips} ->
          if MapSet.member?(referenced, actor.id) do
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
        columns,
        new_skip_ids,
        {refreshed + batch_refreshed, deleted + batch_deleted, errors + batch_errors}
      )
    end
  end

  # Which of `ids` are pointed at by something. Stops as soon as every id is
  # accounted for, so an actor with a follower costs one query, not nineteen.
  defp referenced_ids(_columns, []), do: MapSet.new()

  defp referenced_ids(columns, ids) do
    Enum.reduce_while(columns, MapSet.new(), fn {table, column}, found ->
      case Enum.reject(ids, &MapSet.member?(found, &1)) do
        [] -> {:halt, found}
        remaining -> {:cont, MapSet.union(found, ids_referenced_by(table, column, remaining))}
      end
    end)
  end

  # sobelow_skip ["SQL.Query"]
  defp ids_referenced_by(table, column, ids) do
    sql =
      "SELECT DISTINCT #{quote_identifier(column)} FROM #{quote_identifier(table)} " <>
        "WHERE #{quote_identifier(column)} = ANY($1)"

    %{rows: rows} = Repo.query!(sql, [ids])

    rows |> List.flatten() |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  defp quote_identifier(name) do
    unless Regex.match?(@identifier, name) do
      raise ArgumentError, "unexpected identifier from the database catalog: #{inspect(name)}"
    end

    ~s("#{name}")
  end

  defp schedule_cleanup do
    interval = config(:stale_actor_cleanup_interval) || 86_400_000
    Process.send_after(self(), :cleanup, interval)
  end

  defp config(key) do
    Application.get_env(:baudrate, Baudrate.Federation, []) |> Keyword.get(key)
  end
end
