defmodule Baudrate.Content.BoardArticle do
  @moduledoc """
  Join-table schema linking `boards` to `articles`.

  Each record places an article in a board. The table has a unique
  constraint on `{board_id, article_id}` to prevent duplicates.
  Multiple records for the same article enable cross-posting.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.{Article, Board}

  schema "board_articles" do
    belongs_to :board, Board
    belongs_to :article, Article

    timestamps(type: :utc_datetime)
  end

  @doc "Casts and validates the board-article association."
  def changeset(board_article, attrs) do
    board_article
    |> cast(attrs, [:board_id, :article_id])
    |> validate_required([:board_id, :article_id])
    |> assoc_constraint(:board)
    |> assoc_constraint(:article)
    |> unique_constraint([:board_id, :article_id])
  end
end
