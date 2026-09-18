defmodule Baudrate.Repo.Migrations.IndexSoftDeletedForRetention do
  @moduledoc """
  Indexes the rows the retention purge of soft-deleted content selects.

  `20260918140000_prepare_retention` said `articles` and `comments` "already
  carry a `deleted_at` index, so the third pass needs nothing new". They do
  carry one, but it is partial on the *complement*:

      articles_deleted_at_index ON articles (deleted_at) WHERE deleted_at IS NULL

  That index exists to make the listing queries cheap, and every row it holds
  is a row retention must never touch. `Retention.purge_soft_deleted/1` asks
  for `deleted_at IS NOT NULL AND deleted_at < cutoff` — precisely the rows
  those indexes exclude — so no plan could use them and the pass scanned both
  tables whole, every hour, including the ordinary case where there is nothing
  to purge. That is the cost the earlier migration added its two indexes to
  avoid; this is the third.

  Partial again, and on the other side of the same predicate: soft-deleted
  rows are a small minority, so the index stays small and only carries rows
  the purge is actually interested in.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(
      index(:articles, [:deleted_at],
        where: "deleted_at IS NOT NULL",
        name: :articles_soft_deleted_index,
        concurrently: true
      )
    )

    create(
      index(:comments, [:deleted_at],
        where: "deleted_at IS NOT NULL",
        name: :comments_soft_deleted_index,
        concurrently: true
      )
    )
  end
end
