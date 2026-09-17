defmodule Baudrate.Repo.Migrations.CreateInboundActivities do
  use Ecto.Migration

  # Phase 2C: the inbox stores a verified activity and answers 202, and
  # `InboundWorker` processes it outside the request. Processing used to happen
  # inside the HTTP request, so a remote instance sending many activities (or
  # ones that set off long reply-chain fetches) held web requests and database
  # connections for as long as the work took.
  def change do
    create table(:inbound_activities) do
      # The activity `id`. Unique per signing actor: the same activity delivered
      # twice (to a user inbox and the shared inbox, or retried by its sender)
      # is stored once. Scoping it by signer means one account cannot claim an
      # id another account on its server has yet to send.
      add :activity_id, :text, null: false
      add :activity_type, :string, null: false
      # The request body. Cleared once the activity is processed, whatever the
      # outcome: an activity can be a direct message, and only the id is needed
      # to recognise a duplicate.
      add :activity_json, :text

      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all), null: false

      # Which inbox it arrived at: "shared", "user" or "board", with the local
      # id for the last two. No foreign key: a user or board deleted before
      # processing turns into a rejected activity, not a failed insert.
      add :target_type, :string, null: false
      add :target_id, :bigint

      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :next_attempt_at, :utc_datetime
      add :processed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:inbound_activities, [:remote_actor_id, :activity_id])

    # The worker takes the oldest pending activity of each actor.
    create index(:inbound_activities, [:remote_actor_id, :id],
             where: "status = 'pending'",
             name: :inbound_activities_pending_index
           )

    create index(:inbound_activities, [:processed_at], where: "status <> 'pending'")
  end
end
