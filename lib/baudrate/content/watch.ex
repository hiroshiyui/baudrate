defmodule Baudrate.Content.Watch do
  @moduledoc """
  A board or thread a member asked to be notified about (ADR 0070).

  Exactly one of `board_id` and `article_id` is set, enforced by a check
  constraint and here. Written only by `Baudrate.Content.Watches`' toggles.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "watches" do
    belongs_to :user, Baudrate.Setup.User
    belongs_to :board, Baudrate.Content.Board
    belongs_to :article, Baudrate.Content.Article

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a watch."
  def changeset(watch, attrs) do
    watch
    |> cast(attrs, [:user_id, :board_id, :article_id])
    |> validate_required([:user_id])
    |> validate_exactly_one_target()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:board_id)
    |> foreign_key_constraint(:article_id)
    |> check_constraint(:board_id, name: :watch_exactly_one_target)
    |> unique_constraint([:user_id, :board_id], name: :watches_user_board_unique)
    |> unique_constraint([:user_id, :article_id], name: :watches_user_article_unique)
  end

  defp validate_exactly_one_target(changeset) do
    case {get_field(changeset, :board_id), get_field(changeset, :article_id)} do
      {nil, nil} -> add_error(changeset, :board_id, "either board or article must be set")
      {_, nil} -> changeset
      {nil, _} -> changeset
      _ -> add_error(changeset, :board_id, "cannot watch both a board and an article")
    end
  end
end
