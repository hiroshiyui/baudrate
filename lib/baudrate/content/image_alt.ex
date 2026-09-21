defmodule Baudrate.Content.ImageAlt do
  @moduledoc """
  The rules for an uploaded image's description, shared by every schema that
  stores one.

  Three tables carry the column — `article_images`, `comment_images` and
  `timeline_item_reply_images` — and a fourth kind of image arrives already
  described, inside a peer's `attachment`. One module owns the rule so those
  four cannot drift, the same way `Baudrate.Content.ContentWarning` owns the
  `summary`/`sensitive` pair.

  ## What it is for

  Every gallery image used to render `alt="Image 2"`. That is a position, not
  a description: it tells a screen-reader user which of four images they have
  reached and nothing whatsoever about what is in it, while the link wrapping
  it announced the same string a second time. A description written by the
  person who chose the image is the only thing that fixes that, and it is also
  what the fediverse expects — it federates as the attachment `name`, which
  Mastodon and every other client render as alt text.

  ## Two bounds, for two different reasons

  `@max_length` is 1 500 characters, matching what the ecosystem accepts in
  practice, because a description long enough to be a body is a body. It
  applies to text a member types.

  `from_remote/1` applies the same bound to a peer-supplied `name` **and**
  strips tags first. That string is rendered into an `alt` attribute; HEEx
  escapes attributes, so this is defence in depth rather than the only guard,
  but it is also a remote-controlled string reaching a column, and those get an
  explicit bound at ingest with a `validate_length` backstop in the changeset.

  An empty description normalises to `nil`, never `""`. The distinction
  matters at the rendering end: `nil` means nobody wrote one and the fallback
  applies, where `""` in HTML means "this image is decorative, announce
  nothing" — which for a photograph somebody chose to post is a lie.
  """

  import Ecto.Changeset

  # Long enough for a sentence or three about a picture; short enough that it
  # cannot become the post.
  @max_length 1_500

  @doc "The fields a changeset casts to accept a description."
  @spec fields() :: [atom()]
  def fields, do: [:alt]

  @doc "The longest a description may be."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Normalises and validates the description. Safe on a changeset that did not
  cast it.
  """
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(changeset) do
    changeset
    |> update_change(:alt, &normalize/1)
    |> validate_length(:alt, max: @max_length)
  end

  @doc """
  A peer's attachment `name`, reduced to something safe to store.

  Returns `nil` for anything that sanitises to nothing, so the caller does not
  have to tell an absent description from an empty one.
  """
  @spec from_remote(term()) :: String.t() | nil
  def from_remote(name) when is_binary(name) do
    name
    |> Baudrate.Sanitizer.Native.strip_tags()
    |> normalize()
  end

  def from_remote(_), do: nil

  @doc """
  The description to announce for an image, or `nil` when there is none.

  The one place a renderer asks, so the fallback cannot differ between the
  three galleries.
  """
  @spec describe(map()) :: String.t() | nil
  def describe(%{alt: alt}) when is_binary(alt) and alt != "", do: alt
  def describe(_), do: nil

  defp normalize(nil), do: nil

  defp normalize(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_length)
    end
  end

  defp normalize(other), do: other
end
