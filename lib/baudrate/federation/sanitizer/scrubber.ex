defmodule Baudrate.Federation.Sanitizer.Scrubber do
  @moduledoc """
  Custom HtmlSanitizeEx scrubber for incoming federated HTML content.

  Allowlist: `p`, `br`, `hr`, `h1`–`h6`, `em`, `strong`, `del`, `a`, `code`,
  `pre`, `blockquote`, `ul`, `ol`, `li`, `span`.

  Special rules:
    * `<a>` — only `href` with http/https/relative schemes; forced
      `rel="nofollow noopener noreferrer"`
    * `<span>` — only `class` with values in `h-card`, `hashtag`, `mention`,
      `invisible` (Mastodon microformat classes)
    * All other attributes stripped; all other tags stripped
  """

  require HtmlSanitizeEx.Scrubber.Meta
  alias HtmlSanitizeEx.Scrubber.Meta

  Meta.remove_cdata_sections_before_scrub()
  Meta.strip_comments()

  @safe_span_classes MapSet.new(~w[h-card hashtag mention invisible])

  # <a> — validate href scheme, force rel
  def scrub({"a", attributes, children}) do
    case List.keyfind(attributes, "href", 0) do
      {"href", href} ->
        uri = URI.parse(href)

        if uri.scheme in [nil, "http", "https"] do
          {"a", [{"href", href}, {"rel", "nofollow noopener noreferrer"}], children}
        else
          children
        end

      nil ->
        children
    end
  end

  # <span> — filter class to safe Mastodon microformat values
  def scrub({"span", attributes, children}) do
    case List.keyfind(attributes, "class", 0) do
      {"class", value} ->
        safe =
          value
          |> String.split()
          |> Enum.filter(&MapSet.member?(@safe_span_classes, &1))

        if safe == [] do
          {"span", [], children}
        else
          {"span", [{"class", Enum.join(safe, " ")}], children}
        end

      nil ->
        {"span", [], children}
    end
  end

  Meta.allow_tag_with_these_attributes("p", [])
  Meta.allow_tag_with_these_attributes("br", [])
  Meta.allow_tag_with_these_attributes("hr", [])
  Meta.allow_tag_with_these_attributes("h1", [])
  Meta.allow_tag_with_these_attributes("h2", [])
  Meta.allow_tag_with_these_attributes("h3", [])
  Meta.allow_tag_with_these_attributes("h4", [])
  Meta.allow_tag_with_these_attributes("h5", [])
  Meta.allow_tag_with_these_attributes("h6", [])
  Meta.allow_tag_with_these_attributes("em", [])
  Meta.allow_tag_with_these_attributes("strong", [])
  Meta.allow_tag_with_these_attributes("del", [])
  Meta.allow_tag_with_these_attributes("code", [])
  Meta.allow_tag_with_these_attributes("pre", [])
  Meta.allow_tag_with_these_attributes("blockquote", [])
  Meta.allow_tag_with_these_attributes("ul", [])
  Meta.allow_tag_with_these_attributes("ol", [])
  Meta.allow_tag_with_these_attributes("li", [])

  # Dangerous tags: strip both tag AND content entirely
  def scrub({"script", _attributes, _children}), do: ""
  def scrub({"style", _attributes, _children}), do: ""
  def scrub({"iframe", _attributes, _children}), do: ""
  def scrub({"object", _attributes, _children}), do: ""
  def scrub({"embed", _attributes, _children}), do: ""
  def scrub({"form", _attributes, _children}), do: ""
  def scrub({"input", _attributes, _children}), do: ""
  def scrub({"textarea", _attributes, _children}), do: ""

  Meta.strip_everything_not_covered()
end
