defmodule Baudrate.Repo.Migrations.CreateInviteCodes do
  use Ecto.Migration

  def change do
    create table(:invite_codes) do
      add :code, :string, null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :used_by_id, references(:users, on_delete: :nilify_all)
      add :used_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :max_uses, :integer, default: 1
      add :use_count, :integer, default: 0
      add :revoked, :boolean, default: false

      timestamps()
    end

    create unique_index(:invite_codes, [:code])
    create index(:invite_codes, [:created_by_id])
  end
end
