defmodule Baudrate.Repo.Migrations.AddFollowedUserIdToUserFollows do
  use Ecto.Migration

  def change do
    alter table(:user_follows) do
      add :followed_user_id, references(:users, on_delete: :delete_all)
    end

    # Make remote_actor_id nullable (was NOT NULL)
    execute "ALTER TABLE user_follows ALTER COLUMN remote_actor_id DROP NOT NULL",
            "ALTER TABLE user_follows ALTER COLUMN remote_actor_id SET NOT NULL"

    create index(:user_follows, [:followed_user_id])
    create unique_index(:user_follows, [:user_id, :followed_user_id])

    # Exactly one of remote_actor_id / followed_user_id must be non-null
    create constraint(:user_follows, :exactly_one_target,
             check:
               "(remote_actor_id IS NOT NULL AND followed_user_id IS NULL) OR (remote_actor_id IS NULL AND followed_user_id IS NOT NULL)"
           )
  end
end
