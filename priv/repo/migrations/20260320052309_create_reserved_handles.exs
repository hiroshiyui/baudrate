defmodule Baudrate.Repo.Migrations.CreateReservedHandles do
  use Ecto.Migration

  def change do
    create table(:reserved_handles) do
      add :handle, :string, null: false
      add :handle_type, :string, null: false
      add :reserved_at, :utc_datetime, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:reserved_handles, [:handle])
  end
end
