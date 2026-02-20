defmodule Baudrate.Content.BoardModerator do
  @moduledoc """
  Join-table schema linking `boards` to moderator `users`.

  Each record grants a user moderator status on a board. The table has
  a unique constraint on `{board_id, user_id}` to prevent duplicates.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Board
  alias Baudrate.Setup.User

  schema "board_moderators" do
    belongs_to :board, Board
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(board_moderator, attrs) do
    board_moderator
    |> cast(attrs, [:board_id, :user_id])
    |> validate_required([:board_id, :user_id])
    |> assoc_constraint(:board)
    |> assoc_constraint(:user)
    |> unique_constraint([:board_id, :user_id])
  end
end
