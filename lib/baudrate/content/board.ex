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
    field :min_role_to_view, :string, default: "guest"
    field :min_role_to_post, :string, default: "user"
    field :ap_enabled, :boolean, default: true
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

  @doc "Changeset for updating the board's ActivityPub RSA keypair."
  def ap_key_changeset(board, attrs) do
    board
    |> cast(attrs, [:ap_public_key, :ap_private_key_encrypted])
  end

  @doc "Changeset for creating a board with name, slug, permissions, and optional parent."
  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :description, :slug, :position, :parent_id, :min_role_to_view, :min_role_to_post, :ap_enabled])
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 100)
    |> validate_length(:description, max: 1000)
    |> validate_inclusion(:min_role_to_view, ~w(guest user moderator admin))
    |> validate_inclusion(:min_role_to_post, ~w(user moderator admin))
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> assoc_constraint(:parent)
    |> unique_constraint(:slug)
  end

  @doc """
  Changeset for updating an existing board. Excludes `:slug` (immutable after creation).
  """
  def update_changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :description, :position, :parent_id, :min_role_to_view, :min_role_to_post, :ap_enabled])
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
    |> validate_length(:description, max: 1000)
    |> validate_inclusion(:min_role_to_view, ~w(guest user moderator admin))
    |> validate_inclusion(:min_role_to_post, ~w(user moderator admin))
    |> validate_no_parent_cycle(board)
    |> assoc_constraint(:parent)
  end

  defp validate_no_parent_cycle(changeset, board) do
    case get_change(changeset, :parent_id) do
      nil ->
        changeset

      parent_id ->
        if creates_cycle?(board.id, parent_id) do
          add_error(changeset, :parent_id, "would create a circular reference")
        else
          changeset
        end
    end
  end

  defp creates_cycle?(board_id, parent_id, max_depth \\ 10)
  defp creates_cycle?(_board_id, _parent_id, 0), do: true
  defp creates_cycle?(board_id, parent_id, _max_depth) when parent_id == board_id, do: true

  defp creates_cycle?(board_id, parent_id, max_depth) do
    case Baudrate.Repo.get(__MODULE__, parent_id) do
      nil -> false
      %{parent_id: nil} -> false
      %{parent_id: next_parent} -> creates_cycle?(board_id, next_parent, max_depth - 1)
    end
  end
end
