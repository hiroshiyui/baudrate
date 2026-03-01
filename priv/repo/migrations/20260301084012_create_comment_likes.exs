defmodule Baudrate.Repo.Migrations.CreateCommentLikes do
  use Ecto.Migration

  def change do
    create table(:comment_likes) do
      add :comment_id, references(:comments, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all)
      add :ap_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:comment_likes, [:comment_id, :user_id],
             where: "user_id IS NOT NULL",
             name: :comment_likes_comment_user_index
           )

    create unique_index(:comment_likes, [:comment_id, :remote_actor_id],
             where: "remote_actor_id IS NOT NULL",
             name: :comment_likes_comment_remote_actor_index
           )

    create unique_index(:comment_likes, [:ap_id],
             where: "ap_id IS NOT NULL",
             name: :comment_likes_ap_id_index
           )
  end
end
