defmodule Baudrate.Federation.Sanitizer do
  @moduledoc """
  HTML sanitizer for incoming federated content.

  Distinct from `Content.Markdown` — this handles raw HTML received from
  remote ActivityPub instances. Uses `HtmlSanitizeEx` with a custom scrubber
  for parser-based sanitization that properly handles nested, unclosed, and
  malformed HTML.

  Mastodon wraps mentions in `<span class="h-card">` and hashtags in
  `<span class="hashtag">`. These classes (plus `mention` and `invisible`)
  are preserved; all other class values are stripped.

  `sanitize_display_name/1` uses `HtmlSanitizeEx.strip_tags/1` to strip
  HTML tags and a regex pass for control characters from remote actor
  display names to prevent XSS and homograph attacks.

  Applied **before database storage**, not at render time.
  """

  @doc """
  Sanitizes incoming HTML from remote instances.

  Uses a parser-based approach to strip all tags not in the safe set,
  remove event handlers, and force safe attributes on allowed tags.
  """
  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(nil), do: ""
  def sanitize(""), do: ""

  def sanitize(html) when is_binary(html) do
    HtmlSanitizeEx.Scrubber.scrub(html, Baudrate.Federation.Sanitizer.Scrubber)
  end

  @doc """
  Sanitizes a remote actor display name.
  Strips all HTML tags and control characters, trims whitespace,
  and truncates to a reasonable length.
  """
  @spec sanitize_display_name(String.t() | nil) :: String.t() | nil
  def sanitize_display_name(nil), do: nil

  def sanitize_display_name(name) when is_binary(name) do
    name
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.trim()
    |> truncate_display_name(100)
  end

  defp truncate_display_name(name, max) do
    if String.length(name) > max, do: String.slice(name, 0, max), else: name
  end
end
