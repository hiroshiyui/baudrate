defmodule Baudrate.Repo.Migrations.CreateAnnounces do
  use Ecto.Migration

  def change do
    create table(:announces) do
      add :ap_id, :text, null: false
      add :target_ap_id, :text, null: false
      add :activity_id, :text, null: false
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:announces, [:ap_id])
    create unique_index(:announces, [:target_ap_id, :remote_actor_id])
  end
end
