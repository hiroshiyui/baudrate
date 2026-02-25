defmodule Baudrate.Federation.BoardFollow do
  @moduledoc """
  Schema for tracking outbound follow relationships from local boards
  to remote ActivityPub actors.

  Records that a local board has sent a `Follow` activity to a remote actor.
  The `state` field tracks the lifecycle: `pending` → `accepted` / `rejected`.

  Board follows enable two things:
  1. When `ap_accept_policy` is `"followers_only"`, only content from actors
     the board follows is accepted into the board.
  2. The remote server delivers that actor's new posts to the board's inbox,
     where they are automatically created as articles.

  The `ap_id` stores the outgoing Follow activity's AP ID, used for matching
  incoming `Accept(Follow)` and `Reject(Follow)` responses, and for building
  `Undo(Follow)` activities.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Board
  alias Baudrate.Federation.RemoteActor

  schema "board_follows" do
    belongs_to :board, Board
    belongs_to :remote_actor, RemoteActor

    field :state, :string, default: "pending"
    field :ap_id, :string
    field :accepted_at, :utc_datetime
    field :rejected_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(board_id remote_actor_id state ap_id)a
  @optional_fields ~w(accepted_at rejected_at)a

  @doc "Casts and validates fields for creating or updating a board follow record."
  def changeset(board_follow, attrs) do
    board_follow
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:state, ~w(pending accepted rejected))
    |> foreign_key_constraint(:board_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint([:board_id, :remote_actor_id])
    |> unique_constraint(:ap_id)
  end
end
