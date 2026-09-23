defmodule Baudrate.Repo.Migrations.CreateUserDomainMutes do
  use Ecto.Migration

  # A member hiding a whole server's content from their own views (ADR 0073).
  # Unlike an instance domain block it changes nothing for anyone else, and
  # it never refuses an interaction.
  def change do
    create table(:user_domain_mutes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :domain, :string, size: 255, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_domain_mutes, [:user_id, :domain])
  end
end
