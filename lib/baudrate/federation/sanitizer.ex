defmodule Baudrate.Federation.Sanitizer do
  @moduledoc """
  HTML sanitizer for incoming federated content.

  Distinct from `Content.Markdown` — this handles raw HTML received from
  remote ActivityPub instances. Uses a Rust NIF backed by Ammonia (html5ever
  parser) for robust, parser-based sanitization that properly handles nested,
  unclosed, and malformed HTML.

  Mastodon wraps mentions in `<span class="h-card">` and hashtags in
  `<span class="hashtag">`. These classes (plus `mention` and `invisible`)
  are preserved; all other class values are stripped.

  `sanitize_display_name/1` uses `Baudrate.Sanitizer.Native.strip_tags/1`
  to strip HTML tags and a regex pass for control characters from remote
  actor display names to prevent XSS and homograph attacks.

  `sanitize_username/1` does the same for `preferredUsername`, which the UI
  renders as the actor's canonical `@handle@domain` identity — it must be
  bounded and control-character-free for the same reasons the display name is.

  Applied **before database storage**, not at render time.
  """

  # C0/C1 controls plus the Unicode bidirectional-override and byte-order-mark
  # code points. A right-to-left override inside a handle or display name
  # reverses how the rest of the string renders, which is enough to make
  # `@evil@attacker.example` present itself as another actor's handle. ZWJ /
  # ZWNJ (U+200C, U+200D) are deliberately kept — they are load-bearing in
  # emoji sequences and in Indic and Persian scripts.
  @control_chars ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{200B}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]/u

  @doc """
  Sanitizes incoming HTML from remote instances.

  Uses a parser-based approach to strip all tags not in the safe set,
  remove event handlers, and force safe attributes on allowed tags.
  """
  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(nil), do: ""
  def sanitize(""), do: ""

  def sanitize(html) when is_binary(html) do
    Baudrate.Sanitizer.Native.sanitize_federation(html)
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
    |> Baudrate.Sanitizer.Native.strip_tags()
    |> Baudrate.Sanitizer.Native.decode_html_entities()
    |> String.replace(@control_chars, "")
    |> String.trim()
    |> truncate(100)
  end

  @doc """
  Sanitizes a remote actor's `preferredUsername`.

  The username is the actor's identity anchor: the UI renders it as
  `@username@domain`, and it falls back to being the display name when the
  actor publishes no `name`. It therefore needs the same treatment as the
  display name — tags stripped, control and bidi-override characters removed,
  length bounded — plus collapsing of any internal whitespace, which a real
  `preferredUsername` never contains.

  Returns `nil` when the input is not a binary or sanitizes down to nothing, so
  the caller can fall back to deriving a username from the actor's `id`.
  """
  @spec sanitize_username(String.t() | any()) :: String.t() | nil
  def sanitize_username(username) when is_binary(username) do
    username
    |> Baudrate.Sanitizer.Native.strip_tags()
    |> Baudrate.Sanitizer.Native.decode_html_entities()
    |> String.replace(@control_chars, "")
    |> String.replace(~r/\s+/u, "")
    |> truncate(64)
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  def sanitize_username(_), do: nil

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max), else: text
  end
end
