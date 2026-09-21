defmodule Baudrate.Repo.Migrations.CreateCommentRevisions do
  use Ecto.Migration

  def change do
    create table(:comment_revisions) do
      add :body, :text, null: false
      # The content warning as it stood before the edit (ADR 0052). Removing a
      # warning re-exposes what it hid, which is the edit most worth a record.
      add :summary, :string
      add :sensitive, :boolean, null: false, default: false
      add :comment_id, references(:comments, on_delete: :delete_all), null: false
      add :editor_id, references(:users, on_delete: :nilify_all)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:comment_revisions, [:comment_id])
    create index(:comment_revisions, [:inserted_at])
  end
end
