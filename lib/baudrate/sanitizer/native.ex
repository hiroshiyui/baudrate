defmodule Baudrate.Sanitizer.Native do
  @moduledoc """
  Rustler NIF bindings to the `baudrate_sanitizer` Rust crate.

  Provides three HTML sanitization functions backed by
  [Ammonia](https://github.com/rust-ammonia/ammonia) (html5ever parser):

    * `sanitize_federation/1` — allowlist for incoming AP content
    * `sanitize_markdown/1` — allowlist for local Markdown rendering
    * `strip_tags/1` — strip all HTML tags, preserving text content

  Also provides a pure-Elixir helper:

    * `decode_html_entities/1` — decode the five standard XML/HTML entities
      that Ammonia re-encodes when serializing `strip_tags/1` output.
      Call this after `strip_tags/1` to produce plain text safe for Phoenix
      HEEx templates (which apply their own HTML escaping).
  """

  use Rustler, otp_app: :baudrate, crate: "baudrate_sanitizer"

  @doc "Sanitize incoming federation HTML with a strict allowlist."
  @spec sanitize_federation(String.t()) :: String.t()
  def sanitize_federation(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Sanitize Earmark-rendered Markdown HTML with a permissive allowlist."
  @spec sanitize_markdown(String.t()) :: String.t()
  def sanitize_markdown(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Strip all HTML tags, preserving only text content."
  @spec strip_tags(String.t()) :: String.t()
  def strip_tags(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decodes the five standard XML/HTML entities that Ammonia re-encodes when
  serializing `strip_tags/1` output.

  Ammonia (via html5ever) encodes `&`, `<`, `>`, `"`, and `'` as HTML
  entities even in plain-text content. Call this after `strip_tags/1` so
  the result is plain text that Phoenix HEEx templates can escape correctly
  (without double-encoding `&` into `&amp;amp;`).
  """
  @spec decode_html_entities(String.t()) :: String.t()
  def decode_html_entities(str) when is_binary(str) do
    Regex.replace(~r/&(amp|lt|gt|quot|apos|#39);/, str, fn _, name ->
      case name do
        "amp" -> "&"
        "lt" -> "<"
        "gt" -> ">"
        "quot" -> "\""
        _ -> "'"
      end
    end)
  end
end
