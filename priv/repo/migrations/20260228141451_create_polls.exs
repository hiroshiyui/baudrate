defmodule Baudrate.Repo.Migrations.CreatePolls do
  use Ecto.Migration

  def change do
    create table(:polls) do
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :mode, :string, null: false, default: "single"
      add :closes_at, :utc_datetime
      add :voters_count, :integer, null: false, default: 0
      add :ap_id, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polls, [:article_id])
    create unique_index(:polls, [:ap_id], where: "ap_id IS NOT NULL")

    create table(:poll_options) do
      add :poll_id, references(:polls, on_delete: :delete_all), null: false
      add :text, :string, null: false
      add :position, :integer, null: false
      add :votes_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:poll_options, [:poll_id])

    create table(:poll_votes) do
      add :poll_id, references(:polls, on_delete: :delete_all), null: false
      add :poll_option_id, references(:poll_options, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:poll_votes, [:poll_id, :poll_option_id, :user_id],
             where: "user_id IS NOT NULL",
             name: :poll_votes_local_unique
           )

    create unique_index(:poll_votes, [:poll_id, :poll_option_id, :remote_actor_id],
             where: "remote_actor_id IS NOT NULL",
             name: :poll_votes_remote_unique
           )
  end
end
