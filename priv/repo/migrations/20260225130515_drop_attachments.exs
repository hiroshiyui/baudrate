defmodule Baudrate.Repo.Migrations.DropAttachments do
  use Ecto.Migration

  def up do
    drop table(:attachments)
  end

  def down do
    create table(:attachments) do
      add :original_filename, :string, null: false
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :size, :integer, null: false
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:attachments, [:article_id])
    create index(:attachments, [:user_id])
  end
end
