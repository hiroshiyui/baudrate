defmodule Baudrate.Repo.Migrations.CreateArticleDrafts do
  use Ecto.Migration

  def change do
    create table(:article_drafts) do
      # Everything the composer holds, so resuming restores the whole state
      # and not just the two fields the localStorage hook could reach.
      add :title, :string
      add :body, :text
      add :summary, :string
      add :sensitive, :boolean, default: false, null: false
      add :visibility, :string
      add :forwardable, :boolean, default: true, null: false

      # Plain integer arrays rather than join tables: a draft is one member's
      # private scratch state, never queried by board or by image, and a join
      # table would need its own cascade and its own purge.
      add :board_ids, {:array, :integer}, default: [], null: false
      add :image_ids, {:array, :integer}, default: [], null: false

      add :poll_enabled, :boolean, default: false, null: false
      add :poll_options, {:array, :string}, default: [], null: false
      add :poll_mode, :string
      add :poll_expires, :string

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    # The list page and the auto-restore both read newest-first for one owner.
    create index(:article_drafts, [:user_id, :updated_at])
    # The hourly purge reads by age across every owner.
    create index(:article_drafts, [:updated_at])
  end
end
