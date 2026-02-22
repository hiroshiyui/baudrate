defmodule Baudrate.Repo.Migrations.AddBoardPermissionFields do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :min_role_to_view, :string, null: false, default: "guest"
      add :min_role_to_post, :string, null: false, default: "user"
    end

    # Backfill from existing visibility column
    execute(
      "UPDATE boards SET min_role_to_view = CASE WHEN visibility = 'private' THEN 'user' ELSE 'guest' END",
      "UPDATE boards SET visibility = CASE WHEN min_role_to_view = 'guest' THEN 'public' ELSE 'private' END"
    )
  end
end
