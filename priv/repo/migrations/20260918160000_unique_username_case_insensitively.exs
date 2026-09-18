defmodule Baudrate.Repo.Migrations.UniqueUsernameCaseInsensitively do
  @moduledoc """
  Makes usernames unique without regard to case.

  `users.username` had a plain unique index, so `Admin` could be registered
  while `admin` existed. Two things followed from that:

  - **Impersonation.** The fediverse handle is `@Admin@instance`, and it is a
    genuinely distinct actor — `ActivityPubController.user_actor/2` and
    WebFinger both look the name up with an exact match, and the UI renders
    `@{username}` verbatim. `Auth.ReservedHandle` exists to stop precisely
    this, and board slugs are already compared case-folded
    (`Board.changeset/2` uses `lower(u.username)`); user-to-user collisions
    were the case left open.
  - **A permanent denial of service on mentions.** `get_user_by_username_ci/1`
    matches `lower(username)`, so with both rows present it raised
    `Ecto.MultipleResultsError` — and `notify_mentions/4` runs after the
    insert transaction, so the exception reached the LiveView and killed the
    socket of *anyone* who wrote `@admin` in a post or comment. One throwaway
    registration broke mentions of a chosen account for good.

  Existing collisions are renamed rather than refused: the migration cannot
  ask anybody what to do, and failing to deploy is worse than a suffixed name
  the member can change. The oldest row keeps its name.
  """

  use Ecto.Migration

  def up do
    # Rename the newer rows of any existing collision, oldest-first, so the
    # index below can be created. `_2`, `_3`, … within the 32-character limit.
    execute("""
    WITH ranked AS (
      SELECT id, username,
             row_number() OVER (PARTITION BY lower(username) ORDER BY id) AS rn
      FROM users
    )
    UPDATE users u
    SET username = left(u.username, 30) || '_' || ranked.rn
    FROM ranked
    WHERE u.id = ranked.id AND ranked.rn > 1
    """)

    drop(unique_index(:users, [:username]))
    create(unique_index(:users, ["lower(username)"], name: :users_lower_username_index))
  end

  def down do
    drop(unique_index(:users, ["lower(username)"], name: :users_lower_username_index))
    create(unique_index(:users, [:username]))
  end
end
