defmodule Baudrate.Federation.InboundActivity do
  @moduledoc """
  An activity received at an inbox, stored for `Federation.InboundWorker` to
  process outside the HTTP request (Phase 2C, ADR 0034).

  ## Status

      pending → processed   the handler accepted it
      pending → rejected    the handler refused it (the reason is kept)
      pending → failed      processing crashed or timed out on every attempt

  `activity_json` is cleared when a row leaves `pending`. The row itself stays
  for seven days so a redelivery of the same activity is recognised and
  dropped (`Federation.Inbound.purge_finished/0`).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @statuses ~w(pending processed rejected failed)
  @target_types ~w(shared user board)

  schema "inbound_activities" do
    field :activity_id, :string
    field :activity_type, :string
    field :activity_json, :string
    field :target_type, :string
    field :target_id, :integer
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :next_attempt_at, :utc_datetime
    field :processed_at, :utc_datetime

    belongs_to :remote_actor, Baudrate.Federation.RemoteActor

    timestamps(type: :utc_datetime)
  end

  @doc "The statuses a row can have."
  def statuses, do: @statuses

  @doc "The inbox kinds an activity can arrive at."
  def target_types, do: @target_types
end
