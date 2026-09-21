defmodule BaudrateWeb.ImageAltFallback do
  @moduledoc """
  Gives an `<img>` in stored HTML an accessible name when it has none.

  `alt=""` is not "undescribed". In HTML it is a positive claim — *this image
  is decorative, announce nothing* — and a screen reader honours it by skipping
  the image entirely, so the reader is not even told a picture is there. For a
  photograph somebody chose to post that claim is false
  ([ADR 0061](../../doc/adr/0061-an-image-description-is-not-a-form-field.md)),
  and an `<img>` with no `alt` at all is worse: assistive technology falls back
  to reading the file name or the URL.

  Nothing on this site authors a decorative image inside a post. The two paths
  that put an `<img>` into a `body_html` column are a peer's attachment
  (`InboxHandler.append_attachment_images/2`) and a member's own Markdown, and
  in both an image is the content. An empty `alt` there is therefore always the
  *absence* of a description rather than a statement about the picture, which is
  what makes filling it in safe.

  ## Why at render rather than at ingest

  Same reason as `Baudrate.Media.Rewriter`, and one more of its own.

  Shared: applying it on the way out covers every row already stored, with no
  backfill, and keeps the stored HTML as the peer or the member actually wrote
  it.

  Its own: the fallback is **translated**, and a string chosen at ingest would
  be frozen into the column in whatever locale the ingest process happened to be
  running — a Japanese reader would be read a Mandarin sentence for ever because
  of which request first delivered the comment. Localisation only has a correct
  answer at render time, when there is a reader to localise for.

  ## Why a regex is sufficient here

  The same closed input space `Baudrate.Media.Rewriter` documents: this only
  ever runs on output from `Baudrate.Sanitizer.Native`, whose Ammonia serializer
  emits lowercase tag names and double-quoted, entity-escaped attribute values.
  The pass is idempotent — after it runs, every `<img>` has a non-empty `alt`,
  which is the case it leaves alone.

  Never run this on unsanitized HTML.
  """

  use Gettext, backend: BaudrateWeb.Gettext

  # Every <img> tag, whole. The attribute soup inside it is inspected
  # separately rather than matched in one expression, because "has no alt at
  # all" and "has an empty alt" need different repairs.
  @img_re ~r/<img\b[^>]*>/i
  @alt_re ~r/\balt="([^"]*)"/i
  @empty_alt_re ~r/\balt=""/i
  @open_re ~r/\A<img\b/i

  @doc """
  Fills in a missing or empty `alt` on every `<img>` in already-sanitized HTML.

  Passes `nil` and blank input through unchanged, and leaves an image that
  already has a description alone.
  """
  @spec fill(String.t() | nil) :: String.t() | nil
  def fill(nil), do: nil
  def fill(""), do: ""

  def fill(html) when is_binary(html) do
    Regex.replace(@img_re, html, fn tag -> repair(tag) end)
  end

  def fill(other), do: other

  defp repair(tag) do
    case Regex.run(@alt_re, tag) do
      # Described already: the whole point is to leave this alone.
      [_, value] when value != "" ->
        tag

      [_, ""] ->
        Regex.replace(@empty_alt_re, tag, ~s(alt="#{fallback()}"), global: false)

      nil ->
        # Put it first rather than before the closing delimiter, which may be
        # `>` or `/>`. Attribute order carries no meaning and this cannot
        # mis-parse a tag it does not understand.
        Regex.replace(@open_re, tag, ~s(<img alt="#{fallback()}"), global: false)
    end
  end

  defp fallback do
    gettext("Image with no description") |> escape_attr()
  end

  defp escape_attr(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
