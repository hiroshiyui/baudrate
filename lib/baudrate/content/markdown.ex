defmodule Baudrate.Content.Markdown do
  @moduledoc """
  Converts Markdown text to sanitized HTML using Earmark.

  The rendering pipeline is:

  1. **Earmark** — Markdown → raw HTML
  2. **Ammonia sanitizer** — strips unsafe HTML tags/attributes
  3. **Hashtag linkification** — converts `#tag` to clickable links
     (post-sanitize so the injected `<a class="hashtag">` tags survive)

  The sanitizer only allows `href` on `<a>` tags. By running linkification
  *after* sanitization, the injected `<a>` tags are never stripped. Tag names
  are regex-validated (`\\p{L}[\\w]{0,63}`) so no injection is possible.
  """

  @skip_re ~r/<(pre|code|a)[\s>].*?<\/\1>/su
  @hashtag_re ~r/(?:^|(?<=\s|[^\w&]))#(\p{L}[\w]{0,63})/u

  @doc """
  Renders a Markdown string to sanitized HTML with linkified hashtags.

  Returns an empty string for `nil` or blank input.

  ## Examples

      iex> Baudrate.Content.Markdown.to_html("**bold**")
      "<p>\\n<strong>bold</strong></p>\\n"

      iex> Baudrate.Content.Markdown.to_html(nil)
      ""
  """
  @spec to_html(String.t() | nil) :: String.t()
  def to_html(nil), do: ""
  def to_html(""), do: ""

  def to_html(text) when is_binary(text) do
    text
    |> Earmark.as_html!()
    |> sanitize_html()
    |> linkify_hashtags()
  end

  defp sanitize_html(html) do
    Baudrate.Sanitizer.Native.sanitize_markdown(html)
  end

  @doc false
  def linkify_hashtags(html) do
    parts = Regex.split(@skip_re, html, include_captures: true)

    Enum.map(parts, fn part ->
      if Regex.match?(~r/\A<(pre|code|a)[\s>]/s, part) do
        part
      else
        Regex.replace(@hashtag_re, part, fn full, tag ->
          prefix = String.slice(full, 0, String.length(full) - String.length(tag) - 1)
          downcased = String.downcase(tag)
          ~s[#{prefix}<a href="/tags/#{downcased}" class="hashtag">##{tag}</a>]
        end)
      end
    end)
    |> Enum.join()
  end
end
