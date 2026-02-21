defmodule Baudrate.Repo.Migrations.CreateComments do
  use Ecto.Migration

  def change do
    create table(:comments) do
      add :body, :text, null: false
      add :body_html, :text
      add :ap_id, :text
      add :deleted_at, :utc_datetime

      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :parent_id, references(:comments, on_delete: :nilify_all)
      add :user_id, references(:users, on_delete: :nilify_all)
      add :remote_actor_id, references(:remote_actors, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:comments, [:ap_id], where: "ap_id IS NOT NULL")
    create index(:comments, [:article_id])
    create index(:comments, [:parent_id])
    create index(:comments, [:user_id])
    create index(:comments, [:remote_actor_id])
  end
end
