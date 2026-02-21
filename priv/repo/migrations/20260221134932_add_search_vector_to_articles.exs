defmodule Baudrate.Repo.Migrations.AddSearchVectorToArticles do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE articles
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('english', coalesce(body, '')), 'B')
    ) STORED
    """

    execute "CREATE INDEX articles_search_vector_idx ON articles USING gin(search_vector)"
  end

  def down do
    execute "DROP INDEX IF EXISTS articles_search_vector_idx"
    execute "ALTER TABLE articles DROP COLUMN IF EXISTS search_vector"
  end
end
