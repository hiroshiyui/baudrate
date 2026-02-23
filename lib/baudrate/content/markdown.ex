defmodule Baudrate.Content.Markdown do
  @moduledoc """
  Converts Markdown text to sanitized HTML using Earmark.

  After Earmark renders Markdown to HTML, a post-processing step uses
  a Rust NIF backed by Ammonia (html5ever parser) to strip any HTML tags
  not in a known-safe set. This prevents injection of `<script>`, `<iframe>`,
  or other unsafe elements that users could include as raw HTML in their
  Markdown source.
  """

  @doc """
  Renders a Markdown string to sanitized HTML.

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
  end

  defp sanitize_html(html) do
    Baudrate.Sanitizer.Native.sanitize_markdown(html)
  end
end
