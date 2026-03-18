defmodule Baudrate.Bots.FeedParser do
  @moduledoc """
  Parses RSS 2.0, RSS 1.0 (RDF), Atom 1.0, and JSON Feed documents.

  Delegates feed parsing to the `baudrate_feed_parser` Rustler NIF, which is
  backed by the [`feedparser-rs`](https://github.com/bug-ops/feedparser-rs) Rust
  library.  Raw field values returned by the NIF are then normalized here:

  - Titles: HTML stripped via `Baudrate.Sanitizer.Native.strip_tags/1`, HTML
    entities decoded, whitespace trimmed, truncated to 255 characters.
  - Body: full `content` block preferred over `summary`; sanitized for safe
    rendering via `Baudrate.Sanitizer.Native.sanitize_markdown/1`.
  - Tags: de-duplicated list of plain-text category strings.
  - Publication date: parsed from RFC 3339 string; clamped to the range
    (10 years ago, now]; dates outside this window are discarded.
  - GUID: entry `id` field; falls back to the link URL.  Entries without a
    usable GUID are silently dropped.
  """

  require Logger

  alias Baudrate.Bots.FeedParserNative

  @max_title_length 255

  @doc """
  Parses a feed binary and returns a list of normalized entry maps.

  Each entry is a map with keys:
    * `:guid` — unique identifier (entry id or link URL)
    * `:title` — plain text title (truncated to 255 chars)
    * `:body` — sanitized HTML content
    * `:link` — original source URL
    * `:tags` — list of category strings
    * `:published_at` — `DateTime` or nil

  Returns `{:ok, entries}` or `{:error, reason}`.
  """
  @spec parse(binary()) :: {:ok, [map()]} | {:error, term()}
  def parse(data) when is_binary(data) do
    case FeedParserNative.parse_feed(data) do
      {:ok, raw_entries} ->
        entries =
          raw_entries
          |> Enum.map(&normalize_entry/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Entry normalization ---

  defp normalize_entry(%FeedParserNative.Entry{} = entry) do
    link = entry.link
    guid = if is_binary(entry.id) and entry.id != "", do: entry.id, else: link

    if is_nil(guid) or guid == "" do
      nil
    else
      %{
        guid: guid,
        title: normalize_title(entry.title),
        body: normalize_body(entry.content, entry.summary),
        link: link,
        tags: normalize_tags(entry.tags),
        published_at: clamp_published_at(entry.published_rfc3339)
      }
    end
  end

  defp normalize_title(nil), do: "(untitled)"

  defp normalize_title(raw) when is_binary(raw) do
    trimmed = String.trim(raw)
    text = if trimmed == "", do: "(untitled)", else: trimmed

    # feedparser-rs already decodes XML entities (e.g. &amp; → &), so titles
    # are typically plain text.  Passing plain text with bare `&` through Ammonia
    # would mangle it (Ammonia may interpret bare `&` as the start of an entity
    # reference).  Only invoke strip_tags when the title actually contains markup.
    text =
      if String.contains?(text, "<") do
        text
        |> Baudrate.Sanitizer.Native.strip_tags()
        |> decode_html_entities()
      else
        text
      end

    text
    |> String.trim()
    |> String.slice(0, @max_title_length)
  end

  defp normalize_body(content, summary) do
    raw =
      cond do
        is_binary(content) and content != "" -> content
        is_binary(summary) and summary != "" -> summary
        true -> ""
      end

    Baudrate.Sanitizer.Native.sanitize_markdown(raw)
  end

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp normalize_tags(_), do: []

  # --- Date helpers ---

  defp clamp_published_at(nil), do: nil

  defp clamp_published_at(rfc3339) when is_binary(rfc3339) do
    now = DateTime.utc_now()
    ten_years_ago = DateTime.add(now, -10 * 365 * 24 * 3600, :second)

    case DateTime.from_iso8601(rfc3339) do
      {:ok, dt, _} ->
        cond do
          DateTime.compare(dt, ten_years_ago) == :lt -> nil
          DateTime.compare(dt, now) == :gt -> nil
          true -> dt
        end

      {:error, _} ->
        nil
    end
  end

  # Decodes the five standard XML/HTML entities that Ammonia re-encodes when
  # serializing strip_tags output.  Titles must be plain text so that Phoenix
  # HEEx auto-escaping renders them correctly in the browser.
  defp decode_html_entities(str) do
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
