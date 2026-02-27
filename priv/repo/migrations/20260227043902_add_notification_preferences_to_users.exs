defmodule Baudrate.Repo.Migrations.AddNotificationPreferencesToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :notification_preferences, :map, default: %{}, null: false
    end
  end
end
