defmodule Baudrate.Repo.Migrations.AddFeedItemAndMessageToReports do
  use Ecto.Migration

  # Members can now report a feed item and a direct message they received.
  #
  # `message_body` is a copy of the one reported message, taken when the report
  # is made: moderators never read the conversation itself, and the evidence
  # must survive the sender deleting the message (which overwrites its body).
  def change do
    alter table(:reports) do
      add :feed_item_id, references(:feed_items, on_delete: :nilify_all)
      add :message_id, references(:direct_messages, on_delete: :nilify_all)
      add :message_body, :text
    end

    create index(:reports, [:feed_item_id])
    create index(:reports, [:message_id])
  end
end
