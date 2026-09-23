defmodule Baudrate.Repo.Migrations.CreateDmImages do
  @moduledoc """
  Images attached to direct messages (6D, ADR 0071).

  Private files: served only through `/messages/images/:id` after a
  participant check, never by path. There is no `storage_path` column — the
  path is always rebuilt from `filename` through
  `Baudrate.DataPortability.Files`, the lesson of ADR 0040. `message_id` is
  empty until the message is sent, so a composer's upload has a row to hang
  its description on.
  """

  use Ecto.Migration

  def change do
    create table(:dm_images) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:direct_messages, on_delete: :delete_all)
      add :filename, :string, null: false
      add :width, :integer, null: false
      add :height, :integer, null: false
      add :alt, :text

      timestamps(type: :utc_datetime)
    end

    create index(:dm_images, [:message_id])
    create index(:dm_images, [:user_id])
    create unique_index(:dm_images, [:filename])
  end
end
