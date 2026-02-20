defmodule Baudrate.Repo.Migrations.CreateArticles do
  use Ecto.Migration

  def change do
    create table(:articles) do
      add :title, :string, null: false
      add :body, :text, null: false
      add :slug, :string, null: false
      add :pinned, :boolean, null: false, default: false
      add :locked, :boolean, null: false, default: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:articles, [:slug])
    create index(:articles, [:user_id])
  end
end
