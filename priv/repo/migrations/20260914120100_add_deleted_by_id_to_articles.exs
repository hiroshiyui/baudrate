defmodule Baudrate.Repo.Migrations.AddDeletedByIdToArticles do
  use Ecto.Migration

  # Records which local user soft-deleted an article: the author, or a
  # moderator/admin. The data export (ADR 0023) includes an author's own
  # self-deleted articles but never content removed by moderation, and needs
  # this to tell them apart. Existing soft-deleted rows stay NULL, meaning
  # "attribution unknown", which the export treats as excluded (fail closed).
  # Remote deletions (federation `Delete`, actor cleanup) also leave it NULL.
  def change do
    alter table(:articles) do
      add :deleted_by_id, references(:users, on_delete: :nilify_all)
    end
  end
end
