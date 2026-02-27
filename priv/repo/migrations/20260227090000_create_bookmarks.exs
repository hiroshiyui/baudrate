defmodule Baudrate.Repo.Migrations.CreateBookmarks do
  use Ecto.Migration

  def change do
    create table(:bookmarks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :article_id, references(:articles, on_delete: :delete_all)
      add :comment_id, references(:comments, on_delete: :delete_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:bookmarks, [:user_id, :article_id],
             where: "article_id IS NOT NULL",
             name: :bookmarks_user_article_unique
           )

    create unique_index(:bookmarks, [:user_id, :comment_id],
             where: "comment_id IS NOT NULL",
             name: :bookmarks_user_comment_unique
           )

    create index(:bookmarks, [:user_id])

    # Constraint: exactly one of article_id/comment_id must be set
    execute(
      """
      ALTER TABLE bookmarks ADD CONSTRAINT bookmarks_target_check
      CHECK (
        (article_id IS NOT NULL AND comment_id IS NULL) OR
        (article_id IS NULL AND comment_id IS NOT NULL)
      )
      """,
      "ALTER TABLE bookmarks DROP CONSTRAINT bookmarks_target_check"
    )
  end
end
