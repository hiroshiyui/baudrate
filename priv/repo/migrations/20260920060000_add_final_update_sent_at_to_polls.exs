defmodule Baudrate.Repo.Migrations.AddFinalUpdateSentAtToPolls do
  @moduledoc """
  Records that a closed poll's final counts have been published (Phase 3D).

  A poll closes by the clock — `Poll.closed?/1` compares `closes_at` to now,
  and nothing writes a "closed" state, deliberately (the same reasoning as
  sanctions in ADR 0029: a sweep that misses a run must not hold something
  past its time). That is right for *reading* a poll and wrong for *announcing*
  one, because an announcement is an event and an event needs to happen once.

  Without a marker the hourly sweep would have to infer "recently closed" from
  a time window, and a missed run would then mean the `Update(Question)` never
  goes out at all — remote instances keeping whatever counts they last saw,
  for good. With one, a late run still sends it.

  Nullable and never cast from params: the sweep is the only writer.
  Partial index on the rows the sweep actually selects — the unsent ones —
  which stay a small minority.
  """

  use Ecto.Migration

  def change do
    alter table(:polls) do
      add :final_update_sent_at, :utc_datetime
    end

    create index(:polls, [:closes_at],
             where: "final_update_sent_at IS NULL AND closes_at IS NOT NULL",
             name: :polls_pending_final_update_index
           )
  end
end
