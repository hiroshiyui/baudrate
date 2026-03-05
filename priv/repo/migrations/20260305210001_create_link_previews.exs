defmodule Baudrate.Repo.Migrations.CreateLinkPreviews do
  use Ecto.Migration

  def change do
    create table(:link_previews) do
      add :url, :text, null: false
      add :url_hash, :binary, null: false
      add :title, :string, size: 300
      add :description, :text
      add :image_url, :text
      add :site_name, :string, size: 200
      add :domain, :string, size: 253
      add :image_path, :string
      add :status, :string, null: false, default: "pending"
      add :error, :string
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:link_previews, [:url_hash])
  end
end
