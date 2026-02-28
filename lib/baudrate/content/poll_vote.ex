defmodule Baudrate.Content.PollVote do
  @moduledoc """
  Schema for poll votes.

  Each vote links a user (local) or remote actor to a specific poll option.
  The database enforces uniqueness per `(poll_id, poll_option_id, user_id)` for
  local voters and per `(poll_id, poll_option_id, remote_actor_id)` for remote
  voters, preventing duplicate votes on the same option.

  Vote changing is handled at the context level by deleting existing votes
  before inserting new ones within a transaction.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.{Poll, PollOption}
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Setup.User

  schema "poll_votes" do
    belongs_to :poll, Poll
    belongs_to :poll_option, PollOption
    belongs_to :user, User
    belongs_to :remote_actor, RemoteActor

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a local user vote."
  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:poll_id, :poll_option_id, :user_id])
    |> validate_required([:poll_id, :poll_option_id, :user_id])
    |> assoc_constraint(:poll)
    |> assoc_constraint(:poll_option)
    |> assoc_constraint(:user)
    |> unique_constraint([:poll_id, :poll_option_id, :user_id], name: :poll_votes_local_unique)
  end

  @doc "Changeset for a remote actor vote received via ActivityPub."
  def remote_changeset(vote, attrs) do
    vote
    |> cast(attrs, [:poll_id, :poll_option_id, :remote_actor_id])
    |> validate_required([:poll_id, :poll_option_id, :remote_actor_id])
    |> assoc_constraint(:poll)
    |> assoc_constraint(:poll_option)
    |> assoc_constraint(:remote_actor)
    |> unique_constraint([:poll_id, :poll_option_id, :remote_actor_id],
      name: :poll_votes_remote_unique
    )
  end
end
