defmodule Baudrate.Repo.Migrations.AddUsernameTrigramIndex do
  use Ecto.Migration

  # `Auth.Users.search_users_page/2` (the Users tab on /search) runs a COUNT
  # over the same `ilike(username, '%…%')` its page does, and a leading
  # wildcard cannot use the `lower(username)` unique index. pg_trgm is already
  # installed by 20260222025154, which added the same kind of index for
  # articles and comments.
  def up do
    execute "CREATE INDEX users_username_trgm_idx ON users USING gin(username gin_trgm_ops)"
  end

  def down do
    execute "DROP INDEX IF EXISTS users_username_trgm_idx"
  end
end
