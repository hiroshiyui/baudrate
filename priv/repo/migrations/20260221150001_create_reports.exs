defmodule Baudrate.Repo.Migrations.CreateReports do
  use Ecto.Migration

  def change do
    create table(:reports) do
      add :reason, :text, null: false
      add :status, :string, null: false, default: "open"
      add :reporter_id, references(:users, on_delete: :nilify_all)
      add :article_id, references(:articles, on_delete: :nilify_all)
      add :comment_id, references(:comments, on_delete: :nilify_all)
      add :remote_actor_id, references(:remote_actors, on_delete: :nilify_all)
      add :resolved_by_id, references(:users, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime
      add :resolution_note, :text

      timestamps(type: :utc_datetime)
    end

    create index(:reports, [:status])
    create index(:reports, [:article_id])
    create index(:reports, [:comment_id])
    create index(:reports, [:reporter_id])
  end
end
