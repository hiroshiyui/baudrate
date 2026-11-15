defmodule BaudrateWeb.XML do
  @moduledoc """
  XML escaping for the documents this instance renders from EEx templates.

  The syndication feeds and the sitemap are both fixed XML formats built from
  templates rather than a library, so escaping is the one thing that has to be
  right in both. It lives here so there is a single definition to fix.
  """

  @doc """
  Escapes a string for safe inclusion in XML text nodes and attributes.

  `nil` becomes an empty string, so a template can interpolate an optional
  field without a branch.
  """
  @spec escape(String.t() | nil) :: String.t()
  def escape(nil), do: ""

  def escape(text) when is_binary(text) do
    text
    |> strip_invalid()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  @doc """
  Removes the characters XML 1.0 forbids outright: the C0 controls except
  tab, newline and carriage return, and U+FFFE/U+FFFF. No escape can make
  them legal — `&#1;` is as invalid as the byte — so one in a member's title
  used to make the whole board, site or user feed malformed for every reader.
  """
  @spec strip_invalid(String.t()) :: String.t()
  def strip_invalid(text) when is_binary(text),
    do: String.replace(text, ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{FFFE}\x{FFFF}]/u, "")
end
