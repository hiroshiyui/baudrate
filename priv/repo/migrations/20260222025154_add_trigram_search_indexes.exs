defmodule Baudrate.Repo.Migrations.AddTrigramSearchIndexes do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    # Trigram indexes for CJK search on articles
    execute "CREATE INDEX articles_title_trgm_idx ON articles USING gin(title gin_trgm_ops)"
    execute "CREATE INDEX articles_body_trgm_idx ON articles USING gin(body gin_trgm_ops)"

    # Trigram index for comment search (CJK + English)
    execute "CREATE INDEX comments_body_trgm_idx ON comments USING gin(body gin_trgm_ops)"
  end

  def down do
    execute "DROP INDEX IF EXISTS comments_body_trgm_idx"
    execute "DROP INDEX IF EXISTS articles_body_trgm_idx"
    execute "DROP INDEX IF EXISTS articles_title_trgm_idx"
    # Don't drop pg_trgm extension — other things may use it
  end
end
