defmodule Baudrate.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :type, :string, null: false
      add :read, :boolean, default: false, null: false
      add :data, :map, default: %{}, null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :actor_user_id, references(:users, on_delete: :nilify_all)
      add :actor_remote_actor_id, references(:remote_actors, on_delete: :nilify_all)

      add :article_id, references(:articles, on_delete: :delete_all)
      add :comment_id, references(:comments, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:user_id, :read])
    create index(:notifications, [:user_id, :inserted_at])

    # Dedup indexes use COALESCE(nullable_col, 0) so NULLs are treated as equal.
    # ID 0 never exists, so COALESCE(NULL, 0) produces a safe sentinel value.
    execute(
      """
      CREATE UNIQUE INDEX notifications_dedup_local_index
      ON notifications (user_id, type, actor_user_id, COALESCE(article_id, 0), COALESCE(comment_id, 0))
      WHERE actor_user_id IS NOT NULL
      """,
      "DROP INDEX IF EXISTS notifications_dedup_local_index"
    )

    execute(
      """
      CREATE UNIQUE INDEX notifications_dedup_remote_index
      ON notifications (user_id, type, actor_remote_actor_id, COALESCE(article_id, 0), COALESCE(comment_id, 0))
      WHERE actor_remote_actor_id IS NOT NULL
      """,
      "DROP INDEX IF EXISTS notifications_dedup_remote_index"
    )
  end
end
