defmodule Baudrate.Content.Poll do
  @moduledoc """
  Schema for inline polls attached to articles.

  Each article may have at most one poll (`has_one` relationship with unique
  constraint). Polls support two modes:

    * `"single"` — voters pick exactly one option (rendered as radio buttons)
    * `"multiple"` — voters pick one or more options (rendered as checkboxes)

  An optional `closes_at` timestamp makes the poll time-limited; after that
  point votes are rejected and results become final. The `voters_count` field
  is a denormalized counter updated transactionally when votes are cast.

  Remote polls received via ActivityPub are tracked by `ap_id`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.{Article, PollOption, PollVote}

  schema "polls" do
    field :mode, :string, default: "single"
    field :closes_at, :utc_datetime
    field :voters_count, :integer, default: 0
    field :ap_id, :string

    belongs_to :article, Article
    has_many :options, PollOption, preload_order: [asc: :position]
    has_many :votes, PollVote

    timestamps(type: :utc_datetime)
  end

  @valid_modes ["single", "multiple"]

  @doc "Changeset for creating a local poll."
  def changeset(poll, attrs) do
    poll
    |> cast(attrs, [:mode, :closes_at, :article_id])
    |> validate_required([:mode])
    |> validate_inclusion(:mode, @valid_modes)
    |> validate_closes_at_in_future()
    |> cast_assoc(:options, with: &PollOption.changeset/2, required: true)
    |> validate_option_count()
    |> assoc_constraint(:article)
    |> unique_constraint(:article_id)
  end

  @doc "Changeset for remote polls received via ActivityPub."
  def remote_changeset(poll, attrs) do
    poll
    |> cast(attrs, [:mode, :closes_at, :voters_count, :ap_id, :article_id])
    |> validate_required([:mode])
    |> validate_inclusion(:mode, @valid_modes)
    |> cast_assoc(:options, with: &PollOption.remote_changeset/2, required: true)
    |> assoc_constraint(:article)
    |> unique_constraint(:article_id)
    |> unique_constraint(:ap_id)
  end

  @doc "Returns true if the poll has passed its closing time."
  def closed?(%__MODULE__{closes_at: nil}), do: false

  def closed?(%__MODULE__{closes_at: closes_at}) do
    DateTime.compare(DateTime.utc_now(), closes_at) != :lt
  end

  defp validate_closes_at_in_future(changeset) do
    case get_change(changeset, :closes_at) do
      nil ->
        changeset

      closes_at ->
        if DateTime.compare(closes_at, DateTime.utc_now()) == :gt do
          changeset
        else
          add_error(changeset, :closes_at, "must be in the future")
        end
    end
  end

  defp validate_option_count(changeset) do
    case get_change(changeset, :options) do
      nil ->
        changeset

      options ->
        valid = Enum.reject(options, fn cs -> cs.action == :replace end)
        count = length(valid)

        cond do
          count < 2 -> add_error(changeset, :options, "must have at least 2 options")
          count > 4 -> add_error(changeset, :options, "must have at most 4 options")
          true -> changeset
        end
    end
  end
end
