defmodule Baudrate.Repo.Migrations.AddLegacyApIdToCommentsAndPolls do
  @moduledoc """
  Room to remember the AP id a comment or poll used to have (Phase 3B,
  ADR 0050).

  Local comments were stamped `https://host/ap/users/alice#note-42` and local
  polls `https://host/ap/articles/some-slug#poll`. Both are fragments, and a
  fragment never reaches the server: dereferencing either returns the actor or
  the article, never the object, so no remote instance could ever resolve one.
  `Baudrate.Release.backfill_ap_ids/1` rewrites them to `/ap/comments/:id` and
  `/ap/polls/:id`.

  The rewrite changes a **public identity**. Every instance we already
  delivered a `Create(Note)` to holds the old URI, and ActivityPub has no way
  to tell a peer that an object's id changed — `Move` exists for actors only.
  So the old value is kept rather than discarded, and it is load-bearing in
  both directions:

    * inbound, `Content.get_comment_by_ap_id/1` matches either column, so a
      remote `Like`, `Announce`, `Delete` or `inReplyTo` naming the old URI
      still lands on the right row;
    * outbound, a withdrawal or `Update` for a row that has a `legacy_ap_id`
      is emitted for that id as well, so deleting a pre-backfill comment
      actually removes it from the instances that know it.

  Nullable, because a row created after the backfill has no previous identity
  and must not pretend to. Unique for the same reason `ap_id` is: two rows
  claiming one URI is the ambiguity the column exists to prevent. Partial, so
  the (majority) `NULL` rows cost nothing.
  """

  use Ecto.Migration

  def change do
    alter table(:comments) do
      add :legacy_ap_id, :string
    end

    alter table(:polls) do
      add :legacy_ap_id, :string
    end

    create unique_index(:comments, [:legacy_ap_id], where: "legacy_ap_id IS NOT NULL")
    create unique_index(:polls, [:legacy_ap_id], where: "legacy_ap_id IS NOT NULL")
  end
end
