defmodule Baudrate.Repo.Migrations.AddLinkPreviewIdToContent do
  use Ecto.Migration

  def change do
    alter table(:articles) do
      add :link_preview_id, references(:link_previews, on_delete: :nilify_all)
    end

    alter table(:comments) do
      add :link_preview_id, references(:link_previews, on_delete: :nilify_all)
    end

    alter table(:direct_messages) do
      add :link_preview_id, references(:link_previews, on_delete: :nilify_all)
    end

    alter table(:feed_items) do
      add :link_preview_id, references(:link_previews, on_delete: :nilify_all)
    end

    alter table(:feed_item_replies) do
      add :link_preview_id, references(:link_previews, on_delete: :nilify_all)
    end

    create index(:articles, [:link_preview_id])
    create index(:comments, [:link_preview_id])
    create index(:direct_messages, [:link_preview_id])
    create index(:feed_items, [:link_preview_id])
    create index(:feed_item_replies, [:link_preview_id])
  end
end
