defmodule Baudrate.Content.LinkPreview.UrlExtractor do
  @moduledoc """
  Extracts the first external HTTP(S) URL from rendered HTML content.

  Filters out same-origin URLs, hashtag/mention links, non-HTTP(S) schemes,
  and fragment-only links.
  """

  @doc """
  Extracts the first external URL from HTML content.

  Returns `{:ok, url}` or `:none`.
  """
  @spec extract_first_url(String.t()) :: {:ok, String.t()} | :none
  def extract_first_url(html) when is_binary(html) do
    case Floki.parse_fragment(html) do
      {:ok, tree} ->
        origin = BaudrateWeb.Endpoint.url()

        tree
        |> Floki.find("a[href]")
        |> Enum.find_value(:none, fn element ->
          href = Floki.attribute(element, "href") |> List.first()
          classes = Floki.attribute(element, "class") |> List.first() || ""

          cond do
            is_nil(href) or href == "" ->
              nil

            String.starts_with?(href, "#") ->
              nil

            String.contains?(classes, "hashtag") ->
              nil

            String.contains?(classes, "mention") ->
              nil

            not String.starts_with?(href, "http://") and
                not String.starts_with?(href, "https://") ->
              nil

            String.starts_with?(href, origin) ->
              nil

            true ->
              {:ok, href}
          end
        end)

      _ ->
        :none
    end
  end

  def extract_first_url(_), do: :none
end
