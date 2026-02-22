defmodule Baudrate.Repo.Migrations.CreateArticleImages do
  use Ecto.Migration

  def change do
    create table(:article_images) do
      add :filename, :string, null: false
      add :storage_path, :string, null: false
      add :width, :integer, null: false
      add :height, :integer, null: false
      add :article_id, references(:articles, on_delete: :delete_all), null: true
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:article_images, [:article_id])
    create index(:article_images, [:user_id])
  end
end
