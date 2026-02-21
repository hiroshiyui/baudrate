defmodule Baudrate.Repo.Migrations.MakeArticlesUserIdNullable do
  use Ecto.Migration

  def change do
    alter table(:articles) do
      modify :user_id, references(:users, on_delete: :delete_all),
        null: true,
        from: references(:users, on_delete: :delete_all)
    end
  end
end
