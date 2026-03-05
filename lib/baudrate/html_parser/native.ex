defmodule Baudrate.HtmlParser.Native do
  @moduledoc """
  Rustler NIF bindings to the `baudrate_html_parser` Rust crate.

  Provides HTML parsing functions backed by
  [html5ever](https://github.com/servo/html5ever) via the `scraper` crate:

    * `parse_og_metadata/1` — extract Open Graph / Twitter Card / fallback metadata
    * `extract_first_url/2` — extract the first external URL from an HTML fragment
  """

  use Rustler, otp_app: :baudrate, crate: "baudrate_html_parser"

  defmodule OgMetadata do
    @moduledoc "Struct returned by `parse_og_metadata/1`."
    defstruct [:title, :description, :image_url, :site_name]
  end

  @doc """
  Parse an HTML document and extract OG / Twitter Card / fallback metadata.

  Returns a `%OgMetadata{}` struct with `:title`, `:description`, `:image_url`,
  and `:site_name` fields (all `String.t() | nil`).
  """
  @spec parse_og_metadata(String.t()) :: OgMetadata.t()
  def parse_og_metadata(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Parse an HTML fragment and extract the first external HTTP(S) URL.

  Filters out fragment-only hrefs, hashtag/mention links, non-HTTP(S) schemes,
  and URLs matching the given `origin`.

  Returns the URL string or `nil`.
  """
  @spec extract_first_url(String.t(), String.t()) :: String.t() | nil
  def extract_first_url(_html, _origin), do: :erlang.nif_error(:nif_not_loaded)
end
