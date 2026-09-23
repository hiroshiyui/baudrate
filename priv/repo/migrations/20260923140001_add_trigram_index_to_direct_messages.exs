defmodule Baudrate.Repo.Migrations.AddTrigramIndexToDirectMessages do
  @moduledoc """
  Lets a member search their own conversations with `ILIKE` without a
  sequential scan of every message on the instance (6D). `pg_trgm` is
  already installed for article and comment search.
  """

  use Ecto.Migration

  def up do
    execute(
      "CREATE INDEX direct_messages_body_trgm_index ON direct_messages USING gin (body gin_trgm_ops)"
    )
  end

  def down do
    execute("DROP INDEX direct_messages_body_trgm_index")
  end
end
