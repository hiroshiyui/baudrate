defmodule Baudrate.Repo.Migrations.AddApKeysToBoards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :ap_public_key, :text
      add :ap_private_key_encrypted, :binary
    end
  end
end
