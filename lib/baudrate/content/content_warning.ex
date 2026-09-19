defmodule Baudrate.Content.ContentWarning do
  @moduledoc """
  The content-warning fields, and what they have to mean wherever they appear
  (ADR 0052).

  Articles, comments and timeline items all carry `summary` and `sensitive`,
  from three different directions — a local composer, an inbound
  ActivityPub object, a user-triggered import — and the rules have to be the
  same in all of them, or a renderer has to know which table a row came from.
  One module, called by every changeset that casts the pair.

  Three rules, each of which is a way this can go wrong:

    * **An empty warning is `nil`, never `""`.** Otherwise "does this have a
      warning" has two answers and every template has to know both. A form
      submits `""` for an untouched field, so this is the common case rather
      than an edge one.

    * **Text implies the flag.** A peer that sends a `summary` and forgets
      `sensitive` meant to warn somebody; honouring the text is the reading
      that fails safe. The reverse is *not* true — `sensitive: true` with no
      text is a post marked sensitive with no reason given, which is a thing
      Mastodon allows and which renders as a generic warning.

    * **It is bounded.** A warning is a label, not a post: long enough for a
      sentence, short enough that it cannot become the body in disguise. A
      warning nobody can read past is not a warning. It is also a
      remote-controlled string reaching a column, so it needs an explicit
      bound like every other one.
  """

  import Ecto.Changeset

  # Matches the column width. Mastodon's own spoiler text is capped at 500.
  @max_length 512

  @doc "The fields a changeset casts to accept a content warning."
  @spec fields() :: [atom()]
  def fields, do: [:summary, :sensitive]

  @doc "The longest a warning may be."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Normalises and validates the pair. Safe on a changeset that cast neither.
  """
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(changeset) do
    changeset
    |> update_change(:summary, &normalize/1)
    |> validate_length(:summary, max: @max_length)
    |> imply_sensitive()
  end

  @doc """
  Whether a record should be rendered behind a warning.

  The one predicate, so a template never has to decide for itself what
  counts. `sensitive` alone qualifies: a post marked sensitive with no text
  still gets the generic warning rather than being shown unprompted.
  """
  @spec warned?(map()) :: boolean()
  def warned?(%{sensitive: true}), do: true
  def warned?(%{summary: summary}) when is_binary(summary) and summary != "", do: true
  def warned?(_), do: false

  defp imply_sensitive(changeset) do
    if get_field(changeset, :summary),
      do: put_change(changeset, :sensitive, true),
      else: changeset
  end

  defp normalize(nil), do: nil

  defp normalize(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_length)
    end
  end

  defp normalize(other), do: other
end
