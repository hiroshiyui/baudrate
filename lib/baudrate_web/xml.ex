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
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
