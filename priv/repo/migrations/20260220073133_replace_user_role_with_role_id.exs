defmodule Baudrate.Repo.Migrations.ReplaceUserRoleWithRoleId do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :role_id, references(:roles, on_delete: :restrict)
      remove :role, :string, null: false
    end
  end
end
