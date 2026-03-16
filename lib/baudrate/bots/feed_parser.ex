defmodule Baudrate.Bots.FeedParser do
  @moduledoc """
  Parses RSS 2.0 and Atom 1.0 feeds using the `fiet` library.

  Normalizes feed entries into a consistent map format suitable for
  creating articles. HTML content is sanitized via `Baudrate.Sanitizer.Native`.

  Tries RSS 2.0 parsing first; falls back to Atom 1.0 if RSS fails.
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

          {:error, reason} ->
            {:error, reason}
        end
    end
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
