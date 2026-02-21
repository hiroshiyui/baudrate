defmodule Baudrate.Repo.Migrations.AddApKeysToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :ap_public_key, :text
      add :ap_private_key_encrypted, :binary
    end
  end
end
