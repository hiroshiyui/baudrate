defmodule Baudrate.Content.TitleDeriver do
  @moduledoc """
  Derives article titles from content when no explicit title is available.

  Used when materializing feed items or comments into articles, and by
  the federation inbox handler when receiving AP objects without a `name`
  field.
  """

  @doc """
  Derives a title from an AP object map and body text.

  Article/Page objects use the `"name"` field. For Notes or objects
  without a name, extracts the first line of the body text and truncates
  it to 80 graphemes.

  Returns `"Untitled"` when both the name and body are empty.
  """
  @spec derive_title(map(), String.t() | nil) :: String.t()
  def derive_title(%{"name" => name}, _body) when is_binary(name) and name != "" do
    truncate_title(name, 255)
  end

  def derive_title(_object, body) when is_binary(body) and body != "" do
    body
    |> String.split(~r/\n/, parts: 2)
    |> hd()
    |> String.trim()
    |> truncate_title(80)
    |> case do
      "" -> "Untitled"
      title -> title
    end
  end

  def derive_title(_object, _body), do: "Untitled"

  @doc """
  Derives a title from a plain body string (no AP object context).

  Extracts the first line and truncates to 80 graphemes.
  """
  @spec derive_title_from_body(String.t() | nil) :: String.t()
  def derive_title_from_body(body), do: derive_title(%{}, body)

  @doc """
  Truncates a title to roughly `max_len` graphemes.

  For CJK text (no spaces), cuts at `max_len` and appends "…".
  For space-separated text, breaks at the last word boundary before
  `max_len` to avoid mid-word cuts.
  """
  @spec truncate_title(String.t(), pos_integer()) :: String.t()
  def truncate_title(text, max_len) when is_binary(text) do
    if String.length(text) <= max_len do
      text
    else
      chunk = String.slice(text, 0, max_len)

      case String.contains?(chunk, " ") do
        true ->
          chunk
          |> String.replace(~r/\s+\S*$/, "")
          |> Kernel.<>("…")

        false ->
          chunk <> "…"
      end
    end
  end
end
