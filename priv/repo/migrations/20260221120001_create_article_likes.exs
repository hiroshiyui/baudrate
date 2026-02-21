defmodule Baudrate.Repo.Migrations.CreateArticleLikes do
  use Ecto.Migration

  def change do
    create table(:article_likes) do
      add :ap_id, :text
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:article_likes, [:ap_id], where: "ap_id IS NOT NULL")
    create unique_index(:article_likes, [:article_id, :user_id], where: "user_id IS NOT NULL")

    create unique_index(:article_likes, [:article_id, :remote_actor_id],
      where: "remote_actor_id IS NOT NULL"
    )
  end
end
