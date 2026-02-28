defmodule Baudrate.Content.PollOption do
  @moduledoc """
  Schema for poll options (choices).

  Each option belongs to a poll and has a display text, a position for
  ordering, and a denormalized `votes_count` that is updated
  transactionally when votes are cast or changed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.{Poll, PollVote}

  schema "poll_options" do
    field :text, :string
    field :position, :integer
    field :votes_count, :integer, default: 0

    belongs_to :poll, Poll
    has_many :votes, PollVote

    timestamps(type: :utc_datetime)
  end

  @max_text_length 200

  @doc "Changeset for creating a local poll option."
  def changeset(option, attrs) do
    option
    |> cast(attrs, [:text, :position])
    |> validate_required([:text, :position])
    |> validate_length(:text, max: @max_text_length)
  end

  @doc "Changeset for remote poll options received via ActivityPub."
  def remote_changeset(option, attrs) do
    option
    |> cast(attrs, [:text, :position, :votes_count])
    |> validate_required([:text, :position])
    |> validate_length(:text, max: @max_text_length)
  end
end
