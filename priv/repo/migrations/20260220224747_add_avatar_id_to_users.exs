defmodule Baudrate.Repo.Migrations.AddAvatarIdToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :avatar_id, :string
    end
  end
end
