defmodule Baudrate.Repo.Migrations.CreateCommentImages do
  use Ecto.Migration

  def change do
    create table(:comment_images) do
      add :filename, :text, null: false
      add :storage_path, :text, null: false
      add :width, :integer, null: false
      add :height, :integer, null: false
      add :comment_id, references(:comments, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:comment_images, [:comment_id])
    create index(:comment_images, [:user_id])
  end
end
