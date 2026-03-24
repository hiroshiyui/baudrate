defmodule Baudrate.Sanitizer.Native do
  @moduledoc """
  Rustler NIF bindings to the `baudrate_sanitizer` Rust crate.

  Provides HTML sanitization functions backed by
  [Ammonia](https://github.com/rust-ammonia/ammonia) (html5ever parser):

    * `sanitize_federation/1` — allowlist for incoming AP content
    * `sanitize_markdown/1` — allowlist for local Markdown rendering
    * `strip_tags/1` — strip all HTML tags, preserving text content
    * `normalize_feed_html/1` — sanitize RSS/Atom body HTML and remove
      common feed artefacts (empty paragraphs, excessive line breaks)

  Also provides a pure-Elixir helper:

    * `decode_html_entities/1` — decode the XML/HTML entities that Ammonia
      preserves in `strip_tags/1` output (`&amp;`, `&lt;`, `&gt;`, `&quot;`,
      `&apos;`/`&#39;`, `&nbsp;`). Call this after `strip_tags/1` to produce
      plain text safe for Phoenix HEEx templates (which apply their own HTML
      escaping).
  """

  use Rustler, otp_app: :baudrate, crate: "baudrate_sanitizer"

  @doc "Sanitize incoming federation HTML with a strict allowlist."
  @spec sanitize_federation(String.t()) :: String.t()
  def sanitize_federation(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Sanitize Earmark-rendered Markdown HTML with a permissive allowlist."
  @spec sanitize_markdown(String.t()) :: String.t()
  def sanitize_markdown(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Strip all HTML tags, preserving only text content.

  Leading and trailing `&nbsp;` entities are trimmed from the result.
  Interior `&nbsp;` entities remain (as literal `&nbsp;` strings) and can be
  decoded to spaces by `decode_html_entities/1`.
  """
  @spec strip_tags(String.t()) :: String.t()
  def strip_tags(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Sanitize and normalize HTML from an RSS/Atom feed body.

  Applies the same allowlist as `sanitize_markdown/1` (html5ever via Ammonia),
  then removes common feed artefacts that remain after stripping disallowed
  elements:

  - Empty `<p>` elements (whitespace / `&nbsp;` only) — produced when
    surrounding `<div>` or `<span>` wrappers are stripped by Ammonia.
  - Runs of three or more consecutive `<br>` elements — a hallmark of
    word-processor-generated or old-style blog feed HTML.

  Use this instead of `sanitize_markdown/1` when processing feed content.
  """
  @spec normalize_feed_html(String.t()) :: String.t()
  def normalize_feed_html(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decodes common HTML entities in `strip_tags/1` output.

  Handles:
  - The five XML entities that Ammonia re-encodes when serializing plain-text
    output (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`/`&#39;`)
  - `&nbsp;` — decoded as a regular space (Ammonia preserves `&nbsp;` as a
    literal entity in `strip_tags/1` output; leading/trailing ones are already
    trimmed by `strip_tags/1` itself)

  Call this after `strip_tags/1` so the result is plain text that Phoenix HEEx
  templates can escape correctly (without double-encoding `&` into `&amp;amp;`).
  """
  @entity_pattern ~r/&(amp|lt|gt|quot|apos|#39|nbsp);/

  @spec decode_html_entities(String.t()) :: String.t()
  def decode_html_entities(str) when is_binary(str) do
    Regex.replace(@entity_pattern, str, fn
      _, "amp" -> "&"
      _, "lt" -> "<"
      _, "gt" -> ">"
      _, "quot" -> "\""
      _, "nbsp" -> " "
      _, _ -> "'"
    end)
  end
end
