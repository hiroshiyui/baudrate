defmodule Baudrate.Bots.FeedParser do
  @moduledoc """
  Parses RSS 2.0, Atom 1.0, and RSS 1.0 (RDF) feeds.

  RSS 2.0 and Atom 1.0 are handled by the `fiet` library. RSS 1.0 is parsed
  directly via `Saxy.SimpleForm`. Normalizes feed entries into a consistent
  map format suitable for creating articles. HTML content is sanitized via
  `Baudrate.Sanitizer.Native`.

  Tries RSS 2.0 first; falls back to Atom 1.0; then to RSS 1.0 (RDF).
  """

  require Logger

  @max_title_length 255

  @doc """
  Parses an XML feed string and returns a list of normalized entry maps.

  Each entry is a map with keys:
    * `:guid` — unique identifier (item guid, entry id, or link URL)
    * `:title` — plain text title (truncated to 255 chars)
    * `:body` — sanitized HTML content
    * `:link` — original source URL
    * `:tags` — list of category strings
    * `:published_at` — `DateTime` or nil

  Returns `{:ok, entries}` or `{:error, reason}`.
  """
  @spec parse(binary()) :: {:ok, [map()]} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    # Strip UTF-8 BOM (EF BB BF) if present — some feeds (e.g. ltn.com.tw)
    # prepend a BOM which causes Saxy to reject the leading `<` in `<?xml`.
    xml = strip_bom(xml)

    # Some feeds (e.g. Drupal) embed raw HTML in <title> without CDATA:
    # <title><a href="...">text</a></title>
    # Saxy parses <a> as a nested element, so fiet captures "" for the title.
    # Normalize to plain text before handing off to fiet.
    xml = normalize_title_elements(xml)

    case Fiet.RSS2.parse(xml) do
      {:ok, channel} ->
        entries =
          channel.items
          |> Enum.map(&normalize_rss_item/1)
          |> Enum.filter(& &1)

        {:ok, entries}

      {:error, _} ->
        # Try Atom
        case Fiet.Atom.parse(xml) do
          {:ok, feed} ->
            entries =
              feed.entries
              |> Enum.map(&normalize_atom_entry/1)
              |> Enum.filter(& &1)

            {:ok, entries}

          {:error, _} ->
            parse_rss1(xml)
        end
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(xml), do: xml

  # Strips nested HTML elements from <title> blocks that contain raw markup
  # without a CDATA wrapper. CDATA-wrapped titles are left untouched because
  # Saxy already emits CDATA content as plain characters for fiet to capture.
  #
  # Uses a plain regex (not Ammonia) to strip tags so that XML entity references
  # in the content (e.g. &amp;) are preserved verbatim and correctly decoded by
  # the XML parser. The stripped text is re-wrapped in CDATA so no xml_escape
  # step is needed.
  defp normalize_title_elements(xml) do
    Regex.replace(~r{<title>(.*?)</title>}s, xml, fn full, content ->
      trimmed = String.trim_leading(content)

      if String.contains?(content, "<") and not String.starts_with?(trimmed, "<![CDATA[") do
        plain =
          content
          |> (&Regex.replace(~r{<[^>]+>}, &1, "")).()
          |> String.trim()
          # CDATA sections may not contain "]]>" — escape any occurrence.
          |> String.replace("]]>", "]]]]><![CDATA[>")

        "<title><![CDATA[#{plain}]]></title>"
      else
        full
      end
    end)
  end

  # Decodes the five standard XML/HTML entities that Ammonia re-encodes when
  # serializing strip_tags output. Titles must be stored as plain text so that
  # Phoenix HEEx's auto-escaping renders them correctly in the browser.
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

  # --- RSS 2.0 normalization ---

  defp normalize_rss_item(item) do
    link = item.link
    guid = if is_binary(item.guid) and item.guid != "", do: item.guid, else: link
    title = extract_rss_title(item)
    body = extract_rss_body(item)
    tags = extract_rss_tags(item)
    published_at = clamp_published_at(item.pub_date)

    if is_nil(guid) or guid == "" do
      nil
    else
      %{
        guid: guid,
        title: title,
        body: body,
        link: link,
        tags: tags,
        published_at: published_at
      }
    end
  end

  defp extract_rss_title(item) do
    raw = if is_binary(item.title) and item.title != "", do: item.title, else: "(untitled)"

    raw
    |> Baudrate.Sanitizer.Native.strip_tags()
    |> decode_html_entities()
    |> String.trim()
    |> String.slice(0, @max_title_length)
  end

  defp extract_rss_body(item) do
    content =
      cond do
        is_binary(item.description) and item.description != "" -> item.description
        true -> ""
      end

    Baudrate.Sanitizer.Native.sanitize_markdown(content)
  end

  defp extract_rss_tags(item) do
    item.categories
    |> Enum.map(fn
      %{value: v} when is_binary(v) and v != "" -> v
      _ -> nil
    end)
    |> Enum.filter(& &1)
    |> Enum.uniq()
  end

  # --- Atom normalization ---

  defp normalize_atom_entry(entry) do
    link = extract_atom_link(entry)
    guid = if is_binary(entry.id) and entry.id != "", do: entry.id, else: link
    title = extract_atom_title(entry)
    body = extract_atom_body(entry)
    tags = extract_atom_tags(entry)
    published_at = clamp_published_at(entry.published || entry.updated)

    if is_nil(guid) or guid == "" do
      nil
    else
      %{
        guid: guid,
        title: title,
        body: body,
        link: link,
        tags: tags,
        published_at: published_at
      }
    end
  end

  defp extract_atom_link(entry) do
    entry.links
    |> Enum.find_value(fn
      %{rel: "alternate", href: href} when is_binary(href) and href != "" -> href
      %{rel: nil, href: href} when is_binary(href) and href != "" -> href
      %{href: href} when is_binary(href) and href != "" -> href
      _ -> nil
    end)
  end

  defp extract_atom_title(entry) do
    raw =
      case entry.title do
        {_type, text} when is_binary(text) and text != "" -> text
        text when is_binary(text) and text != "" -> text
        _ -> "(untitled)"
      end

    raw
    |> Baudrate.Sanitizer.Native.strip_tags()
    |> decode_html_entities()
    |> String.trim()
    |> String.slice(0, @max_title_length)
  end

  defp extract_atom_body(entry) do
    content =
      case entry.content do
        {_type, text} when is_binary(text) and text != "" ->
          text

        _ ->
          case entry.summary do
            {_type, text} when is_binary(text) and text != "" -> text
            text when is_binary(text) and text != "" -> text
            _ -> ""
          end
      end

    Baudrate.Sanitizer.Native.sanitize_markdown(content)
  end

  defp extract_atom_tags(entry) do
    entry.categories
    |> Enum.map(fn
      %{term: t} when is_binary(t) and t != "" -> t
      %{label: l} when is_binary(l) and l != "" -> l
      _ -> nil
    end)
    |> Enum.filter(& &1)
    |> Enum.uniq()
  end

  # --- RSS 1.0 (RDF) normalization ---

  # RSS 1.0 feeds use a flat <rdf:RDF> root with <item> siblings rather than
  # nesting items inside a <channel>. fiet does not support this format, so we
  # parse it directly with Saxy.SimpleForm.
  #
  # Relevant namespaces:
  #   xmlns="http://purl.org/rss/1.0/"        — core elements (title, link, description)
  #   xmlns:dc="http://purl.org/dc/elements/1.1/" — dc:date, dc:creator
  #   xmlns:content="http://purl.org/rss/1.0/modules/content/" — content:encoded
  #
  # The rdf:about attribute on <item> is used as the GUID.
  defp parse_rss1(xml) do
    case Saxy.SimpleForm.parse_string(xml) do
      {:ok, {_tag, _attrs, children}} ->
        entries =
          children
          |> Enum.filter(fn
            {"item", _, _} -> true
            _ -> false
          end)
          |> Enum.map(&normalize_rss1_item/1)
          |> Enum.filter(& &1)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_rss1_item({"item", attrs, children}) do
    guid = find_attr(attrs, "rdf:about")
    link = find_child_text(children, "link") || guid
    raw_title = find_child_text(children, "title") || ""
    description = find_child_text(children, "description") || ""
    content = find_child_text(children, "content:encoded") || description
    dc_date = find_child_text(children, "dc:date")

    title =
      if(raw_title == "", do: "(untitled)", else: raw_title)
      |> Baudrate.Sanitizer.Native.strip_tags()
      |> decode_html_entities()
      |> String.trim()
      |> String.slice(0, @max_title_length)

    body = Baudrate.Sanitizer.Native.sanitize_markdown(content)
    published_at = clamp_published_at(dc_date)

    if is_nil(guid) or guid == "" do
      nil
    else
      %{guid: guid, title: title, body: body, link: link, tags: [], published_at: published_at}
    end
  end

  defp find_attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, v} -> v
      _ -> nil
    end)
  end

  # Saxy.SimpleForm emits text nodes (including CDATA) as plain binaries.
  defp find_child_text(children, tag) do
    Enum.find_value(children, fn
      {^tag, _, content} ->
        text = content |> Enum.filter(&is_binary/1) |> Enum.join()
        if text != "", do: String.trim(text), else: nil

      _ ->
        nil
    end)
  end

  # --- Date parsing ---

  defp clamp_published_at(nil), do: nil

  defp clamp_published_at(raw) when is_binary(raw) do
    now = DateTime.utc_now()
    ten_years_ago = DateTime.add(now, -10 * 365 * 24 * 3600, :second)

    case parse_datetime(raw) do
      {:ok, dt} ->
        cond do
          DateTime.compare(dt, ten_years_ago) == :lt -> nil
          DateTime.compare(dt, now) == :gt -> nil
          true -> dt
        end

      :error ->
        nil
    end
  end

  defp clamp_published_at(_), do: nil

  defp parse_datetime(str) when is_binary(str) do
    # Try RFC 3339 / ISO 8601
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        {:ok, dt}

      {:error, _} ->
        # Try RFC 2822 (common in RSS)
        parse_rfc2822(str)
    end
  end

  # RFC 2822 date format commonly used in RSS feeds
  # e.g. "Mon, 02 Jan 2006 15:04:05 -0700"
  defp parse_rfc2822(str) do
    # Strip optional weekday prefix "Mon, "
    str = Regex.replace(~r/^\w{3},\s+/, str, "")

    months = %{
      "Jan" => 1,
      "Feb" => 2,
      "Mar" => 3,
      "Apr" => 4,
      "May" => 5,
      "Jun" => 6,
      "Jul" => 7,
      "Aug" => 8,
      "Sep" => 9,
      "Oct" => 10,
      "Nov" => 11,
      "Dec" => 12
    }

    case Regex.run(
           ~r/^(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+([+-]\d{4}|GMT|UTC|Z)$/,
           String.trim(str)
         ) do
      [_, day, mon, year, hour, min, sec, tz] ->
        with {:ok, month} <- Map.fetch(months, mon),
             {d, ""} <- Integer.parse(day),
             {y, ""} <- Integer.parse(year),
             {h, ""} <- Integer.parse(hour),
             {m, ""} <- Integer.parse(min),
             {s, ""} <- Integer.parse(sec),
             {:ok, naive} <- NaiveDateTime.new(y, month, d, h, m, s),
             offset_secs = parse_tz_offset(tz),
             {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, DateTime.add(dt, -offset_secs, :second)}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_tz_offset("GMT"), do: 0
  defp parse_tz_offset("UTC"), do: 0
  defp parse_tz_offset("Z"), do: 0

  defp parse_tz_offset(<<sign, h1, h2, m1, m2>>) when sign in [?+, ?-] do
    hours = (h1 - ?0) * 10 + (h2 - ?0)
    mins = (m1 - ?0) * 10 + (m2 - ?0)
    offset = hours * 3600 + mins * 60
    if sign == ?+, do: offset, else: -offset
  end

  defp parse_tz_offset(_), do: 0
end
