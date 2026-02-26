defmodule Baudrate.Repo.Migrations.AddCommentsArticleIdPartialIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    drop_if_exists index(:comments, [:article_id])

    create index(:comments, [:article_id],
             where: "deleted_at IS NULL",
             concurrently: true
           )
  end
end
