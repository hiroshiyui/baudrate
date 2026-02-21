defmodule Baudrate.Federation.Sanitizer do
  @moduledoc """
  HTML sanitizer for incoming federated content.

  Distinct from `Content.Markdown` — this handles raw HTML received from
  remote ActivityPub instances. Uses an allowlist-based approach to strip
  unsafe elements while preserving safe formatting.

  Applied **before database storage**, not at render time.
  """

  @safe_tags MapSet.new(~w[
    p br hr
    h1 h2 h3 h4 h5 h6
    em strong del
    a code pre blockquote
    ul ol li
  ])

  @doc """
  Sanitizes incoming HTML from remote instances.

  Strips all tags not in the safe set, removes event handlers,
  and forces safe attributes on allowed tags.
  """
  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(nil), do: ""
  def sanitize(""), do: ""

  def sanitize(html) when is_binary(html) do
    html
    |> strip_dangerous_tags()
    |> strip_comments()
    |> sanitize_tags()
    |> strip_event_handlers()
  end

  # Completely remove <script>, <style>, <iframe>, <object>, <embed>,
  # <form>, <input>, <textarea> and their contents
  defp strip_dangerous_tags(html) do
    Regex.replace(
      ~r/<(script|style|iframe|object|embed|form|input|textarea)\b[^>]*>.*?<\/\1>/isu,
      html,
      ""
    )
  end

  # Strip self-closing dangerous tags (e.g., <script />, <input />)
  defp strip_comments(html) do
    html
    |> String.replace(~r/<!--.*?-->/su, "")
    |> String.replace(
      ~r/<(script|style|iframe|object|embed|form|input|textarea)\b[^>]*\/?>/iu,
      ""
    )
  end

  defp sanitize_tags(html) do
    Regex.replace(~r/<(\/?)([a-zA-Z][a-zA-Z0-9]*)((?:\s[^>]*)?)>/u, html, fn
      _match, slash, tag, attrs ->
        lower = String.downcase(tag)

        if MapSet.member?(@safe_tags, lower) do
          safe_attrs = sanitize_attrs(lower, attrs)
          "<#{slash}#{lower}#{safe_attrs}>"
        else
          # Strip unknown tags entirely (don't escape, just remove the tag)
          ""
        end
    end)
  end

  defp sanitize_attrs("a", attrs) do
    case Regex.run(~r/href="([^"]*)"/, attrs) do
      [_, href] ->
        if safe_link_scheme?(href) do
          safe_href = escape_entities(href)
          ~s( href="#{safe_href}" rel="nofollow noopener noreferrer")
        else
          ""
        end

      _ ->
        ""
    end
  end

  defp sanitize_attrs(_tag, _attrs), do: ""

  defp safe_link_scheme?(href) do
    uri = URI.parse(href)
    uri.scheme in [nil, "http", "https"]
  end

  defp strip_event_handlers(html) do
    # Remove any remaining on* attributes that might have slipped through
    Regex.replace(~r/\s+on\w+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]*)/iu, html, "")
  end

  defp escape_entities(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
