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
    # index below can be created.
    #
    # A single `UPDATE` computing `left(username, 30) || '_' || rn` is not
    # collision-free, and the collision is cheap to arrange: register
    # `repeat('a', 32)`, `repeat('A', 32)` and `repeat('a', 30) || '_2'` —
    # three ordinary sign-ups — and the second is renamed onto the third,
    # which was never a duplicate and is left alone. `CREATE UNIQUE INDEX`
    # then fails and the migration aborts, so the trap is laid *before* the
    # upgrade and springs during it. Truncating to 30 could also emit a
    # 33-character name once `rn` reached 10, past the 32 the changeset
    # allows, leaving an account whose every later edit fails validation.
    #
    # So each name is chosen against the live table and the counter moves
    # until it is free. This terminates (the candidate set is unbounded and
    # the table is finite), cannot collide with an untouched row or with an
    # earlier rename in this same loop, and stays inside 32 characters and
    # the `[A-Za-z0-9_]` the username format allows.
    execute("""
    DO $$
    DECLARE
      colliding record;
      candidate text;
      suffix int;
    BEGIN
      FOR colliding IN
        SELECT id, username FROM (
          SELECT id, username,
                 row_number() OVER (PARTITION BY lower(username) ORDER BY id) AS rn
          FROM users
        ) ranked
        WHERE ranked.rn > 1
        ORDER BY id
      LOOP
        suffix := 2;

        LOOP
          candidate := left(colliding.username, 24) || '_' || suffix;
          EXIT WHEN NOT EXISTS (
            SELECT 1 FROM users WHERE lower(username) = lower(candidate)
          );
          suffix := suffix + 1;
        END LOOP;

        UPDATE users SET username = candidate WHERE id = colliding.id;
      END LOOP;
    END $$
    """)

    # Belt and braces: if anything above failed to converge, say so here
    # rather than inside `CREATE UNIQUE INDEX`, where the error names a key
    # value and not the reason.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM users GROUP BY lower(username) HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'username collisions remain after renaming; refusing to continue';
      END IF;
    END $$
    """)

    drop(unique_index(:users, [:username]))
    create(unique_index(:users, ["lower(username)"], name: :users_lower_username_index))
  end

  def down do
    drop(unique_index(:users, ["lower(username)"], name: :users_lower_username_index))
    create(unique_index(:users, [:username]))
  end
end
