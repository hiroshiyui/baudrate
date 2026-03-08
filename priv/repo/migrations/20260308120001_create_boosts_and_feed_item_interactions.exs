defmodule Baudrate.Repo.Migrations.CreateBoostsAndFeedItemInteractions do
  use Ecto.Migration

  def change do
    # --- Article Boosts ---
    create table(:article_boosts) do
      add :ap_id, :text
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:article_boosts, [:ap_id], where: "ap_id IS NOT NULL")

    create unique_index(:article_boosts, [:article_id, :user_id], where: "user_id IS NOT NULL")

    create unique_index(:article_boosts, [:article_id, :remote_actor_id],
             where: "remote_actor_id IS NOT NULL"
           )

    # --- Comment Boosts ---
    create table(:comment_boosts) do
      add :ap_id, :text
      add :comment_id, references(:comments, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:comment_boosts, [:ap_id], where: "ap_id IS NOT NULL")

    create unique_index(:comment_boosts, [:comment_id, :user_id],
             where: "user_id IS NOT NULL",
             name: :comment_boosts_comment_user_index
           )

    create unique_index(:comment_boosts, [:comment_id, :remote_actor_id],
             where: "remote_actor_id IS NOT NULL",
             name: :comment_boosts_comment_remote_actor_index
           )

    # --- Feed Item Likes ---
    create table(:feed_item_likes) do
      add :ap_id, :text
      add :feed_item_id, references(:feed_items, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feed_item_likes, [:feed_item_id, :user_id])
    create unique_index(:feed_item_likes, [:ap_id], where: "ap_id IS NOT NULL")

    # --- Feed Item Boosts ---
    create table(:feed_item_boosts) do
      add :ap_id, :text
      add :feed_item_id, references(:feed_items, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feed_item_boosts, [:feed_item_id, :user_id])
    create unique_index(:feed_item_boosts, [:ap_id], where: "ap_id IS NOT NULL")
  end
end
