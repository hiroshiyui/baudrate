defmodule Baudrate.Content.BoardRead do
  @moduledoc """
  Schema recording the "mark all as read" floor timestamp per user per board.

  When a user clicks "Mark all as read" on a board, a single row is
  upserted with `read_at` set to now. Any article whose `last_activity_at`
  is at or before this timestamp is considered read, avoiding the need to
  insert individual `ArticleRead` rows for every article.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "board_reads" do
    belongs_to :user, Baudrate.Setup.User
    belongs_to :board, Baudrate.Content.Board
    field :read_at, :utc_datetime
  end

  @doc "Changeset for creating or updating a board read record."
  def changeset(board_read, attrs) do
    board_read
    |> cast(attrs, [:user_id, :board_id, :read_at])
    |> validate_required([:user_id, :board_id, :read_at])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:board_id)
    |> unique_constraint([:user_id, :board_id])
  end
end
