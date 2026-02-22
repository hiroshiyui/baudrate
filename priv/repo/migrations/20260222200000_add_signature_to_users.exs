defmodule Baudrate.Repo.Migrations.AddSignatureToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :signature, :text
    end
  end
end
