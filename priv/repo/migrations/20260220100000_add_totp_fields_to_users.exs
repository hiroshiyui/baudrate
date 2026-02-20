defmodule Baudrate.Repo.Migrations.AddTotpFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :totp_secret, :binary
      add :totp_enabled, :boolean, default: false, null: false
    end
  end
end
