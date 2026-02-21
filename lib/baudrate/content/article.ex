defmodule Baudrate.Content.Article do
  @moduledoc """
  Schema for forum articles (posts).

  An article belongs to an author (user) and can be cross-posted to
  multiple boards via the `board_articles` join table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.{Board, BoardArticle}
  alias Baudrate.Federation.RemoteActor

  schema "articles" do
    field :title, :string
    field :body, :string
    field :slug, :string
    field :pinned, :boolean, default: false
    field :locked, :boolean, default: false
    field :ap_id, :string

    belongs_to :user, Baudrate.Setup.User
    belongs_to :remote_actor, RemoteActor
    has_many :board_articles, BoardArticle
    many_to_many :boards, Board, join_through: "board_articles"

    timestamps(type: :utc_datetime)
  end

  def changeset(article, attrs) do
    article
    |> cast(attrs, [:title, :body, :slug, :pinned, :locked, :user_id])
    |> validate_required([:title, :body, :slug])
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> assoc_constraint(:user)
    |> unique_constraint(:slug)
  end
end
