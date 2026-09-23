defmodule Baudrate.Repo.Migrations.BackfillFollowersAcceptedAt do
  use Ecto.Migration

  # `followers.accepted_at IS NULL` now means a follow request waiting for the
  # member's approval (ADR 0073). Every row written so far was accepted when
  # it was inserted, so none may start pending.
  def up do
    execute("UPDATE followers SET accepted_at = inserted_at WHERE accepted_at IS NULL")
  end

  def down, do: :ok
end
