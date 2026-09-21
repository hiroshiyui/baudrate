defmodule Baudrate.Content.SearchQuery do
  @moduledoc """
  The search box's query string: parsing it, changing one operator in it, and
  deciding whether it names anything.

  A query mixes free text with `key:value` operator tokens
  (`author:alice tag:elixir phoenix tutorial`). This module is the **one**
  definition of that syntax, because there are two ways into it: a reader
  typing operators, and the filter controls on `/search`, which set `board:`
  and the date range by rewriting the query string rather than carrying
  parallel `?board=&from=&to=` parameters. Two paths into one filter is two
  sets of merge rules to get wrong, and a control that can silently disagree
  with the box above it.

  ## A search needs a scope

  `scoped?/1` is the predicate behind that rule: a query must have free text,
  or name a person, a board or a tag. A date range on its own — or
  `has:images` on its own — is refused by `Content.Search` rather than
  answered with everything the viewer can see, which is
  [ADR 0055](../../../doc/adr/0055-unanswered-is-a-river-and-tags-is-a-ranking.md)'s
  river by a different route: *"a cross-board list of articles is a river
  whatever orders it, and filtering by reply count is mostly filtering by
  age"*. Filtering by date alone is the same shape, and newest-first it is
  `/recent` with a filter that removes almost nothing.

  Time is not a scope. A person, a board, a topic or a word is.

  ## Operators

  | Operator | Accumulates | Value |
  |----------|-------------|-------|
  | `author:` | list (OR) | a local username |
  | `board:` | list (OR) | a board slug |
  | `tag:` | list (AND) | a tag, downcased by the caller |
  | `has:` | list (AND) | `images` |
  | `before:` | overwrites | `YYYY-MM-DD` |
  | `after:` | overwrites | `YYYY-MM-DD` |

  Keys are strings throughout — never `String.to_atom/1` on user input. An
  unparsable date is dropped silently, which is what the box has always done.
  """

  @keys ~w(author board tag has before after)
  @list_keys ~w(author board tag has)
  @date_keys ~w(before after)
  @scope_keys ~w(author board tag)

  @operator_re ~r/\b(author|board|tag|has|before|after):(\S+)/

  # Built here rather than interpolated at call time: `put/3` takes a key from
  # the caller, and a regex assembled from a variable is one refactor away from
  # being assembled from a parameter.
  @key_res %{
    "author" => ~r/\bauthor:\S+/,
    "board" => ~r/\bboard:\S+/,
    "tag" => ~r/\btag:\S+/,
    "has" => ~r/\bhas:\S+/,
    "before" => ~r/\bbefore:\S+/,
    "after" => ~r/\bafter:\S+/
  }

  @doc """
  Splits a query string into `{free_text, operators}`.

  List operators accumulate in the order they were written; date operators
  overwrite, so the last one wins. Everything that is not an operator token
  is returned as the free text, with runs of whitespace collapsed.

  ## Examples

      iex> Baudrate.Content.SearchQuery.parse("author:alice tag:elixir phoenix")
      {"phoenix", %{"author" => ["alice"], "tag" => ["elixir"]}}

      iex> Baudrate.Content.SearchQuery.parse("before:not-a-date hello")
      {"hello", %{}}
  """
  @spec parse(String.t()) :: {String.t(), map()}
  def parse(query_string) when is_binary(query_string) do
    operators =
      @operator_re
      |> Regex.scan(query_string)
      |> Enum.reduce(%{}, fn [_full, key, value], acc ->
        cond do
          key in @list_keys ->
            Map.update(acc, key, [value], &(&1 ++ [value]))

          key in @date_keys ->
            case Date.from_iso8601(value) do
              {:ok, date} -> Map.put(acc, key, date)
              _ -> acc
            end
        end
      end)

    {squeeze(Regex.replace(@operator_re, query_string, "")), operators}
  end

  @doc """
  Sets `key` to `value` in a query string, replacing any tokens already there.

  Replacement rather than append is the point: picking a second date in the
  filter controls must not leave `after:2026-01-01 after:2026-02-01`, where
  the second silently wins for dates and both apply for lists. A `nil` or
  blank value removes the operator, which is how "All boards" and an empty
  date field are expressed. The free text and the other operators keep their
  place; the new token goes on the end.

  A value containing whitespace cannot survive a round trip through `parse/1`,
  so it is refused the same way a blank one is.

  ## Examples

      iex> Baudrate.Content.SearchQuery.put("phoenix board:general", "board", "elixir")
      "phoenix board:elixir"

      iex> Baudrate.Content.SearchQuery.put("phoenix board:general", "board", nil)
      "phoenix"
  """
  @spec put(String.t(), String.t(), String.t() | Date.t() | nil) :: String.t()
  def put(query_string, key, value) when is_binary(query_string) and key in @keys do
    stripped = squeeze(Regex.replace(Map.fetch!(@key_res, key), query_string, ""))

    case normalize(value) do
      nil -> stripped
      value -> squeeze(stripped <> " " <> key <> ":" <> value)
    end
  end

  @doc """
  Whether the query names anything to search *within*.

  True for free text, `author:`, `board:` or `tag:`. False for a query that is
  only a date range or only `has:` — see the moduledoc.

  ## Examples

      iex> Baudrate.Content.SearchQuery.scoped?("board:general")
      true

      iex> Baudrate.Content.SearchQuery.scoped?("after:2026-01-01")
      false
  """
  @spec scoped?(String.t()) :: boolean()
  def scoped?(query_string) when is_binary(query_string) do
    {text, operators} = parse(query_string)
    text != "" or Enum.any?(@scope_keys, &Map.has_key?(operators, &1))
  end

  @doc """
  The first value of a list operator, or `nil` — what a single-choice control
  (the board `<select>`) reads its current setting from.
  """
  @spec first(map(), String.t()) :: String.t() | nil
  def first(operators, key) when is_map(operators) do
    case Map.get(operators, key) do
      [value | _] -> value
      _ -> nil
    end
  end

  @doc """
  A date operator formatted for an `<input type="date">`, or `""`.
  """
  @spec date_value(map(), String.t()) :: String.t()
  def date_value(operators, key) when is_map(operators) do
    case Map.get(operators, key) do
      %Date{} = date -> Date.to_iso8601(date)
      _ -> ""
    end
  end

  defp normalize(nil), do: nil
  defp normalize(%Date{} = date), do: Date.to_iso8601(date)

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> if String.match?(trimmed, ~r/\s/), do: nil, else: trimmed
    end
  end

  defp normalize(_), do: nil

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
