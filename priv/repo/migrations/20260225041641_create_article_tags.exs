defmodule Baudrate.Repo.Migrations.CreateArticleTags do
  use Ecto.Migration

  def change do
    create table(:article_tags) do
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :tag, :string, size: 64, null: false

      timestamps(updated_at: false)
    end

    create index(:article_tags, [:tag])
    create unique_index(:article_tags, [:article_id, :tag])
  end
end
