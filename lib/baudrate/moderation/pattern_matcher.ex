defmodule Baudrate.Moderation.PatternMatcher do
  @moduledoc """
  Matching a text against `word`, `substring` and `domain` patterns — the one
  implementation behind an admin's content filters
  (`Baudrate.Moderation.ContentFilters`, ADR 0065) and a member's muted words
  (ADR 0073).

  Linear time, never a regular expression: a pattern is compiled once
  (`compile/1`), a text becomes a corpus once (`corpus/2`), and each match is
  a few binary searches. Text and patterns are compared in
  `Baudrate.Moderation.ContentFilter.normalize_text/1`'s normal form.
  """

  alias Baudrate.Moderation.ContentFilter
  alias Baudrate.Sanitizer.Native, as: Sanitizer

  @doc """
  Compiles `%{kind: …, pattern: …}` (atom or string keys; extra keys kept) for
  `matches?/2`: a `word` pattern becomes the space-bounded run of its words, a
  `substring` pattern the parts between its `*`s.
  """
  @spec compile(map()) :: map()
  def compile(entry) do
    kind = entry[:kind] || entry["kind"]
    pattern = entry[:pattern] || entry["pattern"]

    base =
      entry
      |> Map.new(fn {k, v} -> {to_key(k), v} end)
      |> Map.merge(%{kind: kind, pattern: pattern})

    case kind do
      "word" ->
        Map.put(base, :needle, " " <> Enum.join(ContentFilter.words(pattern), " ") <> " ")

      "substring" ->
        Map.put(base, :parts, String.split(pattern, "*", trim: true))

      _ ->
        base
    end
  end

  defp to_key(k) when is_atom(k), do: k
  defp to_key("kind"), do: :kind
  defp to_key("pattern"), do: :pattern
  defp to_key(k), do: k

  @doc """
  The body as a reader sees it: markup stripped, and the few entities the
  sanitizer writes back turned into characters.
  """
  @spec text_of(String.t() | nil) :: String.t()
  def text_of(nil), do: ""
  def text_of(""), do: ""

  def text_of(html) do
    html
    |> Sanitizer.strip_tags()
    |> String.replace(["&lt;", "&gt;", "&quot;", "&#39;", "&amp;"], fn
      "&lt;" -> "<"
      "&gt;" -> ">"
      "&quot;" -> "\""
      "&#39;" -> "'"
      "&amp;" -> "&"
    end)
  end

  @doc """
  Builds the corpus the patterns are matched against. `texts` are plain
  strings; `html`, when given, also contributes the hosts of its links (for
  `domain` patterns) — the member-side matching passes none, so it never
  parses a document.
  """
  @spec corpus([String.t() | nil], String.t()) :: map()
  def corpus(texts, html \\ "") do
    links =
      if html == "",
        do: [],
        else: Baudrate.HtmlParser.Native.extract_urls(html, BaudrateWeb.Endpoint.url())

    text =
      texts
      |> Enum.filter(&is_binary/1)
      |> Kernel.++(links)
      |> Enum.join("\n")
      |> ContentFilter.normalize_text()

    words = ContentFilter.words(text)

    %{
      text: text,
      words: words,
      word_line: " " <> Enum.join(words, " ") <> " ",
      hosts: links |> Enum.map(&host/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }
  end

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  @doc "Whether one compiled pattern matches the corpus."
  @spec matches?(map(), map()) :: boolean()
  def matches?(%{kind: "word", needle: needle}, corpus),
    do: :binary.match(corpus.word_line, needle) != :nomatch

  def matches?(%{kind: "substring", parts: [part]}, corpus),
    do: :binary.match(corpus.text, part) != :nomatch

  def matches?(%{kind: "substring", parts: parts}, corpus) do
    # Every part must appear somewhere before any word is examined, which
    # rejects nearly every post at the cost of a few scans of the text.
    Enum.all?(parts, &(:binary.match(corpus.text, &1) != :nomatch)) and
      Enum.any?(corpus.words, &parts_in_order?(&1, parts))
  end

  def matches?(%{kind: "domain", pattern: domain}, corpus) do
    suffix = "." <> domain
    Enum.any?(corpus.hosts, &(&1 == domain or String.ends_with?(&1, suffix)))
  end

  def matches?(_pattern, _corpus), do: false

  @doc """
  Whether any of `compiled` matches any of `texts` — the member-side check:
  no Markdown rendering and no link parsing, so it is cheap enough to run
  per post on render. `[]` answers `false` without building anything.
  """
  @spec any_match?([map()], [String.t() | nil]) :: boolean()
  def any_match?([], _texts), do: false

  def any_match?(compiled, texts) do
    corpus = corpus(texts)
    Enum.any?(compiled, &matches?(&1, corpus))
  end

  # Leftmost-first search for each part in turn is enough: a `*` matches any
  # run inside the word, so an earlier match of one part never rules out a
  # later part that a later match would have allowed.
  defp parts_in_order?(_word, []), do: true

  defp parts_in_order?(word, [part | rest]) do
    case :binary.match(word, part) do
      {start, len} ->
        parts_in_order?(binary_part(word, start + len, byte_size(word) - start - len), rest)

      :nomatch ->
        false
    end
  end
end
