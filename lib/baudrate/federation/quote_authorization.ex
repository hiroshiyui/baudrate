defmodule Baudrate.Federation.QuoteAuthorization do
  @moduledoc """
  A stamp approving one remote post's quote of one local article (FEP-044f,
  ADR 0082).

  Served as a `QuoteAuthorization` object at `/ap/quote_authorizations/:id`;
  the quoting server fetches it to check that the quote was approved. Written
  only by `Baudrate.Federation.Quotes`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Article
  alias Baudrate.Federation.RemoteActor

  @type t :: %__MODULE__{}

  # The same bound as an activity or object id (`Validator`): the column is in
  # a unique index, and PostgreSQL refuses an index entry over about 2.7 KB.
  @max_uri_bytes 2048

  schema "quote_authorizations" do
    field :interacting_object_ap_id, :string
    field :request_ap_id, :string

    belongs_to :article, Article
    belongs_to :remote_actor, RemoteActor

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a stamp. Every field is set by the server, never by a form."
  def changeset(stamp, attrs) do
    stamp
    |> cast(attrs, [:article_id, :remote_actor_id, :interacting_object_ap_id, :request_ap_id])
    |> validate_required([
      :article_id,
      :remote_actor_id,
      :interacting_object_ap_id,
      :request_ap_id
    ])
    |> validate_length(:interacting_object_ap_id, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:request_ap_id, max: @max_uri_bytes, count: :bytes)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint([:article_id, :interacting_object_ap_id])
  end
end
