defmodule Baudrate.Repo.Migrations.AddVisibilityToArticlesCommentsFeedItems do
  use Ecto.Migration

  def change do
    alter table(:articles) do
      add :visibility, :string, default: "public", null: false
    end

    alter table(:comments) do
      add :visibility, :string, default: "public", null: false
    end

    alter table(:feed_items) do
      add :visibility, :string, default: "public", null: false
    end

    create constraint(:articles, :articles_visibility_check,
             check: "visibility IN ('public', 'unlisted', 'followers_only', 'direct')"
           )

    create constraint(:comments, :comments_visibility_check,
             check: "visibility IN ('public', 'unlisted', 'followers_only', 'direct')"
           )

    create constraint(:feed_items, :feed_items_visibility_check,
             check: "visibility IN ('public', 'unlisted', 'followers_only', 'direct')"
           )
  end
end
