defmodule Baudrate.Content.Board do
  @moduledoc """
  Schema for forum boards.

  Boards support nesting via `parent_id` for sub-boards.
  Articles are linked through the `board_articles` join table,
  allowing cross-posting to multiple boards.

  ## ActivityPub Fields

    * `ap_public_key` — PEM-encoded RSA public key for ActivityPub federation
    * `ap_private_key_encrypted` — AES-256-GCM encrypted PEM-encoded RSA private key
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.{Article, BoardArticle, BoardModerator}

  schema "boards" do
    field :name, :string
    field :description, :string
    field :slug, :string
    field :position, :integer, default: 0
    field :ap_public_key, :string
    field :ap_private_key_encrypted, :binary

    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :board_articles, BoardArticle
    many_to_many :articles, Article, join_through: "board_articles"
    has_many :board_moderators, BoardModerator
    many_to_many :moderators, Baudrate.Setup.User, join_through: "board_moderators"

    timestamps(type: :utc_datetime)
  end

  def ap_key_changeset(board, attrs) do
    board
    |> cast(attrs, [:ap_public_key, :ap_private_key_encrypted])
  end

  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :description, :slug, :position, :parent_id])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> assoc_constraint(:parent)
    |> unique_constraint(:slug)
  end
end
