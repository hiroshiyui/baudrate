defmodule Baudrate.Repo.Migrations.CreateContentFilters do
  use Ecto.Migration

  def change do
    create table(:content_filters) do
      # Stored normalized (NFKC, lower case, one space between words), so the
      # unique index below compares what the matcher compares.
      add :pattern, :string, null: false
      # word | substring | domain — never a regular expression (ADR 0065).
      add :kind, :string, null: false
      # block | hold | flag (P5-D3).
      add :action, :string, null: false
      # local | remote | both.
      add :applies_to, :string, null: false, default: "both"
      add :enabled, :boolean, null: false, default: true
      add :note, :text

      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:content_filters, [:kind, :pattern])

    # Every match is recorded, whatever the action, so a filter that catches
    # the wrong thing can be found. Who and what, never the text: a blocked
    # post was never published, and this table is not where it gets kept.
    create table(:content_filter_matches) do
      add :content_filter_id, references(:content_filters, on_delete: :delete_all), null: false
      # What was done: block | hold | flag | drop.
      add :action, :string, null: false
      # article | comment | timeline_reply | remote
      add :target_type, :string, null: false
      add :edit, :boolean, null: false, default: false

      add :user_id, references(:users, on_delete: :nilify_all)
      add :remote_actor_id, references(:remote_actors, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:content_filter_matches, [:content_filter_id, :inserted_at])
    # Retention ages rows across every filter.
    create index(:content_filter_matches, [:inserted_at])

    # A report opened by a filter names it, so the queue can say "flagged by
    # a filter" rather than showing a report nobody made.
    alter table(:reports) do
      add :content_filter_id, references(:content_filters, on_delete: :nilify_all)
    end

    create index(:reports, [:content_filter_id])
  end
end
