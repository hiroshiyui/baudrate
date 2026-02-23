defmodule Baudrate.Content.Markdown.Scrubber do
  @moduledoc """
  Custom HtmlSanitizeEx scrubber for Earmark-rendered Markdown HTML.

  Allowlist: `p`, `br`, `hr`, `h1`–`h6`, `em`, `strong`, `del`, `a`, `code`,
  `pre`, `blockquote`, `ul`, `ol`, `li`, `table`, `thead`, `tbody`, `tr`,
  `th`, `td`, `img`.

  Special rules:
    * `<a>` — `href` with http/https/mailto/relative; forced
      `rel="nofollow noopener"`
    * `<code>` — `class` matching `language-[a-zA-Z0-9_+-]+`
    * `<img>` — `src` with http/https/relative; `alt` attribute
    * All other attributes stripped; all other tags stripped
  """

  require HtmlSanitizeEx.Scrubber.Meta
  alias HtmlSanitizeEx.Scrubber.Meta

  Meta.remove_cdata_sections_before_scrub()
  Meta.strip_comments()

  # <a> — validate href scheme, force rel
  def scrub({"a", attributes, children}) do
    case List.keyfind(attributes, "href", 0) do
      {"href", href} ->
        uri = URI.parse(href)

        if uri.scheme in [nil, "http", "https", "mailto"] do
          {"a", [{"href", href}, {"rel", "nofollow noopener"}], children}
        else
          children
        end

      nil ->
        children
    end
  end

  # <code> — allow language-* class for syntax highlighting
  def scrub({"code", attributes, children}) do
    case List.keyfind(attributes, "class", 0) do
      {"class", value} ->
        if Regex.match?(~r/^language-[a-zA-Z0-9_+\-]+$/, value) do
          {"code", [{"class", value}], children}
        else
          {"code", [], children}
        end

      nil ->
        {"code", [], children}
    end
  end

  # <img> — validate src scheme, allow alt
  def scrub({"img", attributes, children}) do
    src_attr =
      case List.keyfind(attributes, "src", 0) do
        {"src", src} ->
          uri = URI.parse(src)
          if uri.scheme in [nil, "http", "https"], do: [{"src", src}], else: []

        nil ->
          []
      end

    alt_attr =
      case List.keyfind(attributes, "alt", 0) do
        {"alt", alt} -> [{"alt", alt}]
        nil -> []
      end

    {"img", src_attr ++ alt_attr, children}
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
  Meta.allow_tag_with_these_attributes("pre", [])
  Meta.allow_tag_with_these_attributes("blockquote", [])
  Meta.allow_tag_with_these_attributes("ul", [])
  Meta.allow_tag_with_these_attributes("ol", [])
  Meta.allow_tag_with_these_attributes("li", [])
  Meta.allow_tag_with_these_attributes("table", [])
  Meta.allow_tag_with_these_attributes("thead", [])
  Meta.allow_tag_with_these_attributes("tbody", [])
  Meta.allow_tag_with_these_attributes("tr", [])
  Meta.allow_tag_with_these_attributes("th", [])
  Meta.allow_tag_with_these_attributes("td", [])

  # Dangerous tags: strip both tag AND content entirely
  def scrub({"script", _attributes, _children}), do: ""
  def scrub({"style", _attributes, _children}), do: ""
  def scrub({"iframe", _attributes, _children}), do: ""
  def scrub({"object", _attributes, _children}), do: ""
  def scrub({"embed", _attributes, _children}), do: ""
  def scrub({"form", _attributes, _children}), do: ""
  def scrub({"input", _attributes, _children}), do: ""
  def scrub({"textarea", _attributes, _children}), do: ""
  def scrub({"svg", _attributes, _children}), do: ""
  def scrub({"math", _attributes, _children}), do: ""

  Meta.strip_everything_not_covered()
end
