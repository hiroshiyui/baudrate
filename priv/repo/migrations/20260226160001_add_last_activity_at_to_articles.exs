defmodule Baudrate.Repo.Migrations.AddLastActivityAtToArticles do
  use Ecto.Migration

  def up do
    alter table(:articles) do
      add :last_activity_at, :utc_datetime
    end

    flush()

    # Backfill: set last_activity_at to the latest non-deleted comment's
    # inserted_at, or fall back to the article's own inserted_at.
    execute """
    UPDATE articles
    SET last_activity_at = COALESCE(
      (SELECT MAX(c.inserted_at) FROM comments c
       WHERE c.article_id = articles.id AND c.deleted_at IS NULL),
      articles.inserted_at
    )
    """

    alter table(:articles) do
      modify :last_activity_at, :utc_datetime,
        null: false,
        default: fragment("(NOW() AT TIME ZONE 'UTC')")
    end

    create index(:articles, [:last_activity_at])
  end

  def down do
    drop_if_exists index(:articles, [:last_activity_at])

    alter table(:articles) do
      remove :last_activity_at
    end
  end
end
