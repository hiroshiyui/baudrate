defmodule Baudrate.Repo.Migrations.CreateUserBlocks do
  use Ecto.Migration

  def change do
    create table(:user_blocks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :blocked_user_id, references(:users, on_delete: :delete_all), null: true
      add :blocked_actor_ap_id, :string, null: true

      timestamps(updated_at: false)
    end

    create unique_index(:user_blocks, [:user_id, :blocked_user_id],
             where: "blocked_user_id IS NOT NULL",
             name: :user_blocks_local_unique
           )

    create unique_index(:user_blocks, [:user_id, :blocked_actor_ap_id],
             where: "blocked_actor_ap_id IS NOT NULL",
             name: :user_blocks_remote_unique
           )

    create index(:user_blocks, [:user_id])

    # At least one of blocked_user_id or blocked_actor_ap_id must be set
    create constraint(:user_blocks, :must_block_something,
             check: "blocked_user_id IS NOT NULL OR blocked_actor_ap_id IS NOT NULL"
           )
  end
end
