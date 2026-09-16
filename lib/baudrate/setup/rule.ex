defmodule Baudrate.Setup.Rule do
  @moduledoc """
  One numbered site rule.

  Rules are records rather than a single markdown document so that a report can
  cite the rule it says was broken (P1-D9). The `rule_violation` category could
  only ever say "breaks a rule" and never which, because a blob has no
  addressable parts.

  A rule is **retired**, never deleted (`retired_at`). It then disappears from
  `/rules` and from the report dialog, but a report filed months ago still
  resolves to the rule its author meant; a hard delete would quietly empty the
  citation on every past report that named it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "rules" do
    field :position, :integer
    field :title, :string
    field :body, :string
    field :retired_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for writing a rule's text.

  `position` and `retired_at` are deliberately not cast: ordering and retiring
  are their own context operations, and a form that could set either would let
  one rule take another's place in the list by accident.
  """
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:title, :body])
    |> update_change(:title, &trim/1)
    |> update_change(:body, &trim/1)
    |> validate_required([:title])
    |> validate_length(:title, max: 200)
    |> validate_length(:body, max: 10_000)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
