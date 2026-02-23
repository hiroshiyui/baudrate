defmodule Baudrate.Repo.Migrations.AddDeletedAtIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:articles, [:deleted_at], where: "deleted_at IS NULL", concurrently: true)
    create index(:comments, [:deleted_at], where: "deleted_at IS NULL", concurrently: true)
  end
end
