defmodule Baudrate.Repo.Migrations.CreateModerationLogs do
  use Ecto.Migration

  def change do
    create table(:moderation_logs) do
      add :action, :string, null: false
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :target_type, :string
      add :target_id, :integer
      add :details, :map, default: %{}

      timestamps(updated_at: false)
    end

    create index(:moderation_logs, [:action])
    create index(:moderation_logs, [:actor_id])
    create index(:moderation_logs, [:inserted_at])
  end
end
