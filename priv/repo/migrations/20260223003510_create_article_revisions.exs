defmodule Baudrate.Repo.Migrations.CreateArticleRevisions do
  use Ecto.Migration

  def change do
    create table(:article_revisions) do
      add :title, :string, null: false
      add :body, :text, null: false
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :editor_id, references(:users, on_delete: :nilify_all)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:article_revisions, [:article_id])
    create index(:article_revisions, [:inserted_at])
  end
end
