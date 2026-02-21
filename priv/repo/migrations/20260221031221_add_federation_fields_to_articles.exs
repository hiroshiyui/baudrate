defmodule Baudrate.Repo.Migrations.AddFederationFieldsToArticles do
  use Ecto.Migration

  def change do
    alter table(:articles) do
      add :ap_id, :text
      add :remote_actor_id, references(:remote_actors, on_delete: :nilify_all)
    end

    create unique_index(:articles, [:ap_id], where: "ap_id IS NOT NULL")
    create index(:articles, [:remote_actor_id])
  end
end
