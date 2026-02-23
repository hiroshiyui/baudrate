defmodule Baudrate.Repo.Migrations.CreateDirectMessages do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      add :user_a_id, references(:users, on_delete: :nilify_all)
      add :remote_actor_a_id, references(:remote_actors, on_delete: :nilify_all)
      add :user_b_id, references(:users, on_delete: :nilify_all)
      add :remote_actor_b_id, references(:remote_actors, on_delete: :nilify_all)
      add :ap_context, :text
      add :last_message_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Local-local conversations: unique pair
    create unique_index(:conversations, [:user_a_id, :user_b_id],
      where: "user_a_id IS NOT NULL AND user_b_id IS NOT NULL",
      name: :conversations_local_pair_index
    )

    # Local-remote conversations: unique pair (user_a is local, remote_actor_b is remote)
    create unique_index(:conversations, [:user_a_id, :remote_actor_b_id],
      where: "user_a_id IS NOT NULL AND remote_actor_b_id IS NOT NULL",
      name: :conversations_local_remote_pair_index
    )

    # Ensure at least two participants
    create constraint(:conversations, :conversations_two_participants,
      check: """
      (user_a_id IS NOT NULL OR remote_actor_a_id IS NOT NULL) AND
      (user_b_id IS NOT NULL OR remote_actor_b_id IS NOT NULL)
      """
    )

    create index(:conversations, [:user_a_id])
    create index(:conversations, [:user_b_id])
    create index(:conversations, [:remote_actor_a_id])
    create index(:conversations, [:remote_actor_b_id])
    create index(:conversations, [:last_message_at])

    create table(:direct_messages) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :body, :text, null: false
      add :body_html, :text
      add :sender_user_id, references(:users, on_delete: :nilify_all)
      add :sender_remote_actor_id, references(:remote_actors, on_delete: :nilify_all)
      add :ap_id, :text
      add :ap_in_reply_to, :text
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Exactly one sender
    create constraint(:direct_messages, :direct_messages_one_sender,
      check: """
      (sender_user_id IS NOT NULL AND sender_remote_actor_id IS NULL) OR
      (sender_user_id IS NULL AND sender_remote_actor_id IS NOT NULL)
      """
    )

    create unique_index(:direct_messages, [:ap_id], where: "ap_id IS NOT NULL")
    create index(:direct_messages, [:conversation_id, :inserted_at])
    create index(:direct_messages, [:sender_user_id])
    create index(:direct_messages, [:sender_remote_actor_id])

    create table(:conversation_read_cursors) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :last_read_message_id, references(:direct_messages, on_delete: :nilify_all)
      add :last_read_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversation_read_cursors, [:conversation_id, :user_id])
  end
end
