defmodule Baudrate.Repo.Migrations.CreateUserMutes do
  use Ecto.Migration

  def change do
    create table(:user_mutes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :muted_user_id, references(:users, on_delete: :delete_all), null: true
      add :muted_actor_ap_id, :string, null: true

      timestamps(updated_at: false)
    end

    create unique_index(:user_mutes, [:user_id, :muted_user_id],
             where: "muted_user_id IS NOT NULL",
             name: :user_mutes_local_unique
           )

    create unique_index(:user_mutes, [:user_id, :muted_actor_ap_id],
             where: "muted_actor_ap_id IS NOT NULL",
             name: :user_mutes_remote_unique
           )

    create index(:user_mutes, [:user_id])

    # At least one of muted_user_id or muted_actor_ap_id must be set
    create constraint(:user_mutes, :must_mute_something,
             check: "muted_user_id IS NOT NULL OR muted_actor_ap_id IS NOT NULL"
           )
  end
end
