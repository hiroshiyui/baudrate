defmodule Baudrate.Content.Markdown do
  @moduledoc """
  Converts Markdown text to sanitized HTML using Earmark.

  The rendering pipeline is:

  1. **Block normalization** — inserts blank lines between consecutive HTML
     block elements so Earmark treats each as a separate HTML block. Required
     for bot articles whose bodies are stored as sanitized HTML rather than
     Markdown (e.g. RSS feed content where paragraphs abut with no blank lines).
  2. **Earmark** — Markdown → raw HTML
  3. **Ammonia sanitizer** — strips unsafe HTML tags/attributes
  4. **Hashtag linkification** — converts `#tag` to clickable links
  5. **Mention linkification** — converts `@username` to clickable profile links

  The sanitizer only allows `href` on `<a>` tags. By running linkification
  *after* sanitization, the injected `<a>` tags are never stripped. Tag names
  and usernames are regex-validated so no injection is possible.
  """

  @skip_re ~r/<(pre|code|a)[\s>].*?<\/\1>/su
  @hashtag_re ~r/(?:^|(?<=\s|[^\w&]))#(\p{L}[\w]{0,63})/u
  @mention_re ~r/(?:^|(?<=\s|[^\w]))@([a-zA-Z0-9_]{3,32})(?=\s|[^\w]|\z)/u

  @doc """
  Renders a Markdown string to sanitized HTML with linkified hashtags and mentions.

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
    |> normalize_html_blocks()
    |> Earmark.as_html!()
    |> sanitize_html()
    |> linkify_hashtags()
    |> linkify_mentions()
  end

  defp sanitize_html(html) do
    Baudrate.Sanitizer.Native.sanitize_markdown(html)
  end

  # Inserts blank lines between consecutive block-level HTML elements so that
  # Earmark treats each as a separate HTML block. Without this, HTML content
  # stored by feed bots (where paragraphs are adjacent with no blank lines)
  # causes Earmark to drop all paragraphs after the first.
  defp normalize_html_blocks(text) do
    text
    |> String.trim()
    |> then(
      &Regex.replace(
        ~r{</(p|div|blockquote|h[1-6]|ul|ol|li|pre|table|thead|tbody|tr)>},
        &1,
        "</\\1>\n\n"
      )
    )
    |> String.trim()
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

  @doc false
  def linkify_mentions(html) do
    parts = Regex.split(@skip_re, html, include_captures: true)

    Enum.map(parts, fn part ->
      if Regex.match?(~r/\A<(pre|code|a)[\s>]/s, part) do
        part
      else
        Regex.replace(@mention_re, part, fn full, username ->
          prefix = String.slice(full, 0, String.length(full) - String.length(username) - 1)
          downcased = String.downcase(username)
          ~s[#{prefix}<a href="/users/#{downcased}" class="mention">@#{username}</a>]
        end)
      end
    end)
    |> Enum.join()
  end

  @doc """
  Extracts unique downcased `@username` mentions from raw markdown text.

  Operates on raw markdown (before HTML conversion). Fenced code blocks and
  inline code are stripped before matching to avoid false positives.

  ## Examples

      iex> Baudrate.Content.Markdown.extract_mentions("Hello @Alice and @bob")
      ["alice", "bob"]

      iex> Baudrate.Content.Markdown.extract_mentions(nil)
      []
  """
  @spec extract_mentions(String.t() | nil) :: [String.t()]
  def extract_mentions(nil), do: []
  def extract_mentions(""), do: []

  def extract_mentions(text) when is_binary(text) do
    text
    |> strip_code_blocks()
    |> then(&Regex.scan(@mention_re, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp strip_code_blocks(text) do
    text
    |> String.replace(~r/```.*?```/su, "")
    |> String.replace(~r/`[^`]+`/u, "")
  end
end
