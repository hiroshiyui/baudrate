defmodule Baudrate.Repo.Migrations.CreateAnnouncements do
  use Ecto.Migration

  # Phase 7B: a notice an admin shows on every page. It starts when it is
  # created and ends at `ends_at`, or when an admin ends it early; ended rows
  # are kept as the record of what was said. A member's dismissal is a row, so
  # it follows them between devices; a guest's stays in their browser.
  def change do
    create table(:announcements) do
      add :body, :text, null: false
      add :ends_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:announcements, [:ends_at])

    create table(:announcement_dismissals) do
      add :announcement_id, references(:announcements, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:announcement_dismissals, [:user_id, :announcement_id])
    create index(:announcement_dismissals, [:announcement_id])
  end
end
