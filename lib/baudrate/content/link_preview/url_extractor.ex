defmodule Baudrate.Content.LinkPreview.UrlExtractor do
  @moduledoc """
  Extracts the first external HTTP(S) URL from rendered HTML content.

  Filters out same-origin URLs, hashtag/mention links, non-HTTP(S) schemes,
  and fragment-only links. Uses html5ever NIF for HTML parsing.
  """

  alias Baudrate.HtmlParser.Native, as: HtmlParser

  @doc """
  Extracts the first external URL from HTML content.

  Returns `{:ok, url}` or `:none`.
  """
  @spec extract_first_url(String.t()) :: {:ok, String.t()} | :none
  def extract_first_url(html) when is_binary(html) do
    origin = BaudrateWeb.Endpoint.url()

    case HtmlParser.extract_first_url(html, origin) do
      url when is_binary(url) -> {:ok, url}
      nil -> :none
    end
  end

  def extract_first_url(_), do: :none
end
